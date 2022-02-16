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

module Control.Monad.Coroutine.Enumerator
   (
      coroutineEnumerator, enumeratorCoroutine,
      coroutineIteratee, iterateeCoroutine,
      iterateeStreamCoroutine, streamCoroutineIteratee
   )
where

import Control.Monad (liftM, unless)
import Control.Exception.Base (SomeException)

import Data.Enumerator (Enumerator, Iteratee(..), Stream(..))
import qualified Data.Enumerator as Enumerator

import Control.Monad.Coroutine
import Control.Monad.Coroutine.SuspensionFunctors (Await(Await), Yield(Yield), yield)


-- | Converts an 'Iteratee' into a 'Coroutine' parameterized with the 'Await' [x] functor. The coroutine treats an empty
-- input chunk as 'EOF'.
iterateeCoroutine :: Monad m => Iteratee a m b -> Coroutine (Await [a]) m (Either SomeException (b, [a]))
iterateeCoroutine = convert . iterateeStreamCoroutine
   where convert = liftM (either Left (Right . streamChunk)) . mapSuspension convertSuspension
         convertSuspension (Await cont) = Await (endOnEmptyChunk cont)
         endOnEmptyChunk cont [] = cont EOF
         endOnEmptyChunk cont chunk = cont (Chunks chunk)
         streamChunk (b, EOF) = (b, [])
         streamChunk (b, Chunks chunk) = (b, chunk)

-- | Converts a 'Coroutine' parameterized with the 'Await' [x] functor, treating an empty input chunk as 'EOF', into an
-- 'Iteratee'.
coroutineIteratee :: Monad m => Coroutine (Await [a]) m (Either SomeException (b, [a])) -> Iteratee a m b
coroutineIteratee = streamCoroutineIteratee . convert . liftM (either Left (Right . \(b, chunk)-> (b, Chunks chunk)))
   where convert cort = Coroutine {resume= resume cort >>= return . either (Left . convertSuspension) Right}
         convertSuspension (Await cont) = Await (ignoreEmptyChunks (convert . cont))
         ignoreEmptyChunks cont (Chunks []) = suspend $ Await (ignoreEmptyChunks cont)
         ignoreEmptyChunks cont (Chunks chunk) = cont chunk
         ignoreEmptyChunks cont EOF = cont []

-- | Converts an 'Iteratee' into a 'Coroutine' parameterized with the 'Await' ('Stream' x) functor.
iterateeStreamCoroutine :: Monad m => 
                           Iteratee a m b -> Coroutine (Await (Stream a)) m (Either SomeException (b, Stream a))
iterateeStreamCoroutine iter = Coroutine{resume= liftM convertStep $ runIteratee iter}
   where convertStep (Enumerator.Yield b s) = Right $ Right (b, s)
         convertStep (Enumerator.Error e) = Right $ Left e
         convertStep (Enumerator.Continue cont) = Left (Await (iterateeStreamCoroutine . cont))

-- | Converts a 'Coroutine' parameterized with the 'Await' functor into an 'Iteratee'.
streamCoroutineIteratee :: Monad m 
                           => Coroutine (Await (Stream a)) m (Either SomeException (b, Stream a)) -> Iteratee a m b
streamCoroutineIteratee c = Iteratee (liftM convertStep $ resume c)
   where convertStep (Left (Await cont)) = Enumerator.Continue (streamCoroutineIteratee . cont)
         convertStep (Right (Left e)) = Enumerator.Error e
         convertStep (Right (Right (b, s))) = Enumerator.Yield b s

-- | Converts an 'Enumerator' into a 'Coroutine' parameterized with the 'Yield' functor.
enumeratorCoroutine :: Monad m => Enumerator a (Coroutine (Yield [a]) m) () -> Coroutine (Yield [a]) m ()
enumeratorCoroutine enum = runIteratee (enum step) >> return ()
   where step = Enumerator.Continue yielding
         yielding (Chunks xs) = Iteratee (unless (null xs) (yield xs) >> return step)
         yielding EOF = Enumerator.returnI (Enumerator.Yield () EOF)

-- | Converts a 'Coroutine' parameterized with the 'Yield' functor into an 'Enumerator'.
coroutineEnumerator :: Monad m => Coroutine (Yield [a]) m b -> Enumerator a m c
coroutineEnumerator c step@(Enumerator.Continue cont) = Iteratee (resume c >>= either feed (const $ return step))
   where feed (Yield chunk c') = runIteratee (cont (Chunks chunk)) >>= runIteratee . coroutineEnumerator c'
coroutineEnumerator _ step = Enumerator.returnI step
