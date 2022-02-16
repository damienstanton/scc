{- 
    Copyright 2010 Mario Blazevic

    This file is part of the Streaming Component Combinators (SCC) project.

    The SCC project is free software: you can redistribute it and/or modify it under the terms of the GNU General Public
    License as published by the Free Software Foundation, either version 3 of the License, or (at your option) any later
    version.

    SCC is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY; without even the implied warranty
    of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU General Public License for more details.

    You should have received a copy of the GNU General Public License along with SCC.  If not, see
    <http://www.gnu.org/licenses/>.
-}

-- | This module provides a bridge between the Control.Monad.Coroutine and the Data.Enumerator monad transformers.

module Control.Monad.Coroutine.Iteratee
   (
      coroutineEnumerator, enumeratorCoroutine,
      coroutineIteratee, iterateeCoroutine,
      iterateeStreamCoroutine, streamCoroutineIteratee
   )
where

import Control.Monad (liftM)
import Control.Exception.Base (SomeException)
import Data.Monoid (Monoid, mconcat)

import Data.Iteratee.Base (Iteratee(..), Stream(..), icont, idone, idoneM)
import Data.Iteratee.Iteratee (Enumerator)

import Control.Monad.Coroutine
import Control.Monad.Coroutine.SuspensionFunctors (Await(Await), Yield(Yield), yield)


-- | Converts an 'Iteratee' into a 'Coroutine' parameterized with the 'Await' [x] functor. The coroutine treats an empty
-- input chunk as 'EOF'.
iterateeCoroutine :: (Monad m, Monoid s) => Iteratee s m b -> Coroutine (Await [s]) m (Either SomeException (b, [s]))
iterateeCoroutine = convert . iterateeStreamCoroutine
   where convert = liftM streamChunk . mapSuspension convertSuspension
         convertSuspension (Await cont) = Await (endOnEmptyChunk cont)
         endOnEmptyChunk cont [] = cont (EOF Nothing)
         endOnEmptyChunk cont xs = cont (Chunk $ mconcat xs)
         streamChunk (Left e) = Left e
         streamChunk (Right (_, EOF (Just e))) = Left e
         streamChunk (Right (b, EOF Nothing)) = Right (b, [])
         streamChunk (Right (b, Chunk chunk)) = Right (b, [chunk])

-- | Converts a 'Coroutine' parameterized with the 'Await' [x] functor, treating an empty input chunk as 'EOF', into an
-- 'Iteratee'.
coroutineIteratee :: (Monad m, Monoid s) => Coroutine (Await [s]) m (Either SomeException (b, [s])) -> Iteratee s m b
coroutineIteratee = streamCoroutineIteratee . convert 
                    . liftM (either Left (Right . \(b, chunk)-> (b, Chunk $ mconcat chunk)))
   where convert cort = Coroutine {resume= resume cort >>= return . either (Left . convertSuspension) Right}
         convertSuspension (Await cont) = Await (ignoreEmptyChunks (convert . cont))
         ignoreEmptyChunks cont (Chunk chunk) = cont [chunk]
         ignoreEmptyChunks cont EOF{} = cont []

-- | Converts an 'Iteratee' into a 'Coroutine' parameterized with the 'Await' ('Stream' x) functor.
iterateeStreamCoroutine :: Monad m =>
                           Iteratee s m b -> Coroutine (Await (Stream s)) m (Either SomeException (b, Stream s))
iterateeStreamCoroutine iter = Coroutine{resume= runIter iter convertDone convertContinue}
   where convertDone b s = return (Right $ Right (b, s))
         convertContinue _ (Just e) = return (Right $ Left e)
         convertContinue cont Nothing = return (Left $ Await (iterateeStreamCoroutine . cont))

-- | Converts a 'Coroutine' parameterized with the 'Await' functor into an 'Iteratee'.
streamCoroutineIteratee :: Monad m => 
                           Coroutine (Await (Stream s)) m (Either SomeException (b, Stream s)) -> Iteratee s m b
streamCoroutineIteratee c = Iteratee (\done continue-> resume c >>= convertStep done continue)
   where convertStep _ continue (Left (Await cont)) = continue (streamCoroutineIteratee . cont) Nothing
         convertStep _ continue (Right (Left e)) = continue (const $ streamCoroutineIteratee $ return (Left e)) (Just e)
         convertStep done _ (Right (Right (b, s))) = done b s

-- | Converts an 'Enumerator' into a 'Coroutine' parameterized with the 'Yield' functor.
enumeratorCoroutine :: Monad m => Enumerator s (Coroutine (Yield [s]) m) () -> Coroutine (Yield [s]) m ()
enumeratorCoroutine enum = enum (icont step Nothing) >> return ()
   where step (Chunk c) = Iteratee (\_ continue-> yield [c] >> continue step Nothing)
         step s@EOF{} = idone () s

-- | Converts a 'Coroutine' parameterized with the 'Yield' functor into an 'Enumerator'.
coroutineEnumerator :: (Monad m, Monoid s) => Coroutine (Yield [s]) m b -> Enumerator s m c
coroutineEnumerator c i = runIter i idoneM continue
   where feed step (Yield chunk c') = coroutineEnumerator c' (step (Chunk $ mconcat chunk))
         continue step Nothing = resume c >>= either (feed step) (const $ return $ step (EOF Nothing))
         continue step e = return (icont step e)
