{- 
    Copyright 2010-2011 Mario Blazevic

    This file is part of the Streaming Component Combinators (SCC) project.

    The SCC project is free software: you can redistribute it and/or modify it under the terms of the GNU General Public
    License as published by the Free Software Foundation, either version 3 of the License, or (at your option) any later
    version.

    SCC is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY; without even the implied warranty
    of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU General Public License for more details.

    You should have received a copy of the GNU General Public License along with SCC.  If not, see
    <http://www.gnu.org/licenses/>.
-}

-- | The Control.Monad.Coroutine.Enumerator tests.

module Main where

import Control.Exception (assert)
import Control.Exception.Base (SomeException)
import Control.Monad (liftM)
import qualified Data.List as List
import Data.Maybe (fromJust)
import System.Environment (getArgs)

import Debug.Trace

import Data.Enumerator (Enumerator, Iteratee(..), Stream(..), enumList, enumEOF, ($$), (>==>))
import qualified Data.Enumerator as Enumerator
import qualified Data.Enumerator.List as Enumerator.List
import Data.Functor.Identity (runIdentity)

import Control.Monad.Coroutine
import Control.Monad.Coroutine.Enumerator
import Control.Monad.Coroutine.SuspensionFunctors (Await(Await), Yield(Yield), await, yield, weaveAwaitYield)
import Control.Monad.Parallel


streamToList :: Await (Stream a) b -> Await [a] b
streamToList (Await cont) = Await (\chunk-> cont $ if null chunk then EOF else Chunks chunk)

listToStream :: Await [a] b -> Await (Stream a) b
listToStream (Await cont) = Await (cont . unChunks)
   where unChunks (Chunks l) = l
         unChunks EOF = []

sumCoroutine :: Monad m => Coroutine (Await [Integer]) m (Either SomeException (Integer, [Integer]))
sumCoroutine = sum' 0
  where sum' s = do ns <- await
                    if null ns then return (Right (s, [])) else sum' (s + List.sum ns)

yieldAll :: Monad m => [Integer] -> Coroutine (Yield [Integer]) m ()
yieldAll = mapM_ yield . List.groupBy (\m n-> m `mod` 10 == n `mod` 10)

sumIteratee :: Monad m => Iteratee Integer m Integer
sumIteratee = Enumerator.List.fold (+) 0

testSumCI :: Monad m => [Integer] -> m Integer
testSumCI list = liftM (\(Enumerator.Yield s _)-> s) $ 
                 runIteratee ((enumList 10 list >==> enumEOF) $$ coroutineIteratee sumCoroutine)

testSumEC :: MonadParallel m => [Integer] -> m Integer
testSumEC list = pogoStick runIdentity $
                 liftM (\(Right (s, _), _)-> s) $ 
                 weave bindM2 (weaveAwaitYield []) sumCoroutine (enumeratorCoroutine (enumList 10 list >==> enumEOF))

testSumCE :: Monad m => [Integer] -> m Integer
testSumCE list = liftM (\(Enumerator.Yield s _)-> s) $ 
                 runIteratee ((coroutineEnumerator (yieldAll list) >==> enumEOF) $$ sumIteratee)

testSumIC :: MonadParallel m => [Integer] -> m Integer
testSumIC list = pogoStick runIdentity $
                 liftM (\(Right (s, _), _)-> s) $ 
                 weave bindM2 (weaveAwaitYield []) (iterateeCoroutine sumIteratee) (yieldAll list)

testSum list = do s1 <- testSumCI list
                  s2 <- testSumEC list
                  s3 <- testSumCE list
                  s4 <- testSumIC list
                  assert (s1 == s2 && s2 == s3 && s3 == s4) (return s4)

main = do args <- getArgs
          if List.length args /= 4
             then putStr help
             else do let [taskName, monad, size, coroutineCount] = args
                         task :: MonadParallel m => m Integer
                         task = case taskName of "sum" -> testSum [1 .. read size]
                                                 _ -> error (help ++ "Bad task.")
                     result <- case monad of "Maybe" -> return $ fromJust task
                                             "[]" -> return $ List.head task
                                             "Identity" -> return $ runIdentity task
                                             "IO" -> task
                                             _ -> error (help ++ "Bad monad.")
                     print result

help = "Usage: test-enumerator <task> <monad> <size> <coroutines>?\n"
       ++ "  where <task>       is 'sum',\n"
       ++ "        <monad>      is 'Identity', 'Maybe', '[]', or 'IO',\n"
       ++ "        <size>       is the size of the task,\n"
       ++ "    and <coroutines> is the number of coroutines to employ.\n"
  