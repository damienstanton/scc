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

-- | The Control.Monad.Coroutine.Iteratee tests.

module Main where

import Control.Exception.Base (SomeException)
import Control.Monad.Trans.Class (lift)
import Data.Monoid (Monoid)

import Data.ByteString (ByteString)
import Data.Text.Encoding (decodeUtf8)

import Network.HTTP.Enumerator
import Data.Iteratee.ZLib
import Data.Iteratee.IO

import qualified Data.Enumerator as E
import qualified Data.Iteratee as I

import Control.Monad.Coroutine
import Control.Monad.Coroutine.SuspensionFunctors
import Control.Monad.Coroutine.Nested
import qualified Control.Monad.Coroutine.Enumerator as CE
import qualified Control.Monad.Coroutine.Iteratee as CI

import Control.Concurrent.SCC.Sequential

main = do unzip <- enumInflate GZip defaultDecompressParams (CI.coroutineIteratee consumer)
          request <- parseUrl address
          -- httpRedirect (\_ _-> E.coroutineIteratee $ I.iterateeCoroutine unzip) request
          httpRedirect (\_ _-> CE.coroutineIteratee consumer) request

iterateeI2E :: (Monoid s, Monad m) => I.Iteratee s m a -> E.Iteratee s m a
iterateeI2E = CE.coroutineIteratee . CI.iterateeCoroutine

iterateeE2I :: (Monoid s, Monad m) => E.Iteratee s m a -> I.Iteratee s m a
iterateeE2I = CI.coroutineIteratee . CE.iterateeCoroutine

enumeratorI2E :: (Monoid s, Monad m) => I.Enumerator s (Coroutine (Yield [s]) m) () -> E.Enumerator s m ()
enumeratorI2E = CE.coroutineEnumerator . CI.enumeratorCoroutine

enumeratorE2I :: (Monoid s, Monad m) => E.Enumerator s (Coroutine (Yield [s]) m) () -> I.Enumerator s m ()
enumeratorE2I = CI.coroutineEnumerator . CE.enumeratorCoroutine

address = "http://hackage.haskell.org/packages/archive/iteratee/0.6.0.1/iteratee-0.6.0.1.tar.gz"

-- main = enumInflate GZip defaultDecompressParams (coroutineIteratee consumer)
--        >>= flip fileDriver "tmp/A.hs.gz"

consumer :: Coroutine (Await [ByteString]) IO (Either SomeException ((), [ByteString]))
consumer = pipe translator (consume worker) >> return (Right ((), []))

translator :: Functor f => Sink IO (EitherFunctor (Await [a]) f) a -> Coroutine (EitherFunctor (Await [a]) f) IO ()
translator sink = do chunks <- liftParent await
                     if null chunks
                        then lift (putStrLn "END")
                        else putAll chunks sink >> translator sink
         
worker :: Consumer IO ByteString ()
worker = toChars >-> toFile "iteratee"

-- worker = toChars
--          >-> parseXMLTokens
--          >-> foreach (xmlElementHavingTagWith (xmlAttributeValue `having` substring "enumerator")
--                       `nestedIn` xmlElementContent)
--                      (coerce >-> toStdOut)
--                      suppress

toChars :: Monad m => Transducer m ByteString Char
toChars = oneToOneTransducer decodeUtf8 >-> coerce
