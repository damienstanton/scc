{-
    Copyright 2010-2013 Mario Blazevic

    This file is part of the Streaming Component Combinators (SCC) project.

    The SCC project is free software: you can redistribute it and/or modify it under the terms of the GNU General Public
    License as published by the Free Software Foundation, either version 3 of the License, or (at your option) any later
    version.

    SCC is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY; without even the implied warranty
    of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU General Public License for more details.

    You should have received a copy of the GNU General Public License along with SCC.  If not, see
    <http://www.gnu.org/licenses/>.
-}

-- | This module defines 'Source' and 'Sink' types and 'pipe' functions that create them. The method 'get' on 'Source'
-- abstracts away 'Control.Monad.Coroutine.SuspensionFunctors.await', and the method 'put' on 'Sink' is a higher-level
-- abstraction of 'Control.Monad.Coroutine.SuspensionFunctors.yield'. With this arrangement, a single coroutine can
-- yield values to multiple sinks and await values from multiple sources with no need to change the
-- 'Control.Monad.Coroutine.Coroutine' functor. The only requirement is that each functor of the sources and sinks the
-- coroutine uses must be an 'Control.Monad.Coroutine.Nested.AncestorFunctor' of the coroutine's own functor. For
-- example, a coroutine that takes two sources and one sink might be declared like this:
-- 
-- @
-- zip :: forall m a1 a2 a3 d x y. (Monad m, AncestorFunctor a1 d, AncestorFunctor a2 d, AncestorFunctor a3 d)
--        => Source m a1 [x] -> Source m a2 [y] -> Sink m a3 [(x, y)] -> Coroutine d m ()
-- @
-- 
-- Sources, sinks, and coroutines communicating through them are all created using the 'pipe' function or one of its
-- variants. They effectively split the current coroutine into a producer-consumer coroutine pair. The producer gets a
-- new 'Sink' to write to and the consumer a new 'Source' to read from, in addition to all the streams they inherit from
-- the current coroutine. The following function, for example, uses the /zip/ coroutine declard above to add together
-- the pairs of values from two Integer sources:
--
-- @
-- add :: forall m a1 a2 a3 d. (Monad m, AncestorFunctor a1 d, AncestorFunctor a2 d, AncestorFunctor a3 d)
--        => Source m a1 [Integer] -> Source m a2 [Integer] -> Sink m a3 [Integer] -> Coroutine d m ()
-- add source1 source2 sink = do pipe
--                                  (\pairSink-> zip source1 source2 pairSink)                         -- producer
--                                  (\pairSource-> mapStream (List.map $ uncurry (+)) pairSource sink) -- consumer
--                               return ()
-- @

{-# LANGUAGE ScopedTypeVariables, Rank2Types, TypeFamilies, KindSignatures #-}

module Control.Concurrent.SCC.Streams
   (
    -- * Sink and Source types
    Sink, Source, SinkFunctor, SourceFunctor, AncestorFunctor,
    -- * Sink and Source constructors
    pipe, pipeP, pipeG, nullSink,
    -- * Operations on sinks and sources
    -- ** Singleton operations
    get, getWith, getPrime, peek, put, tryPut,
    -- ** Lifting functions
    liftSink, liftSource,
    -- ** Bulk operations
    -- *** Fetching and moving data
    pour, pour_, tee, teeSink,
    getAll, putAll, putChunk,
    getParsed, getRead,
    getWhile, getUntil, 
    pourRead, pourParsed, pourWhile, pourUntil,
    Reader, Reading(..), ReadingResult(..),
    -- *** Stream transformations
    markDown, markUpWith,
    mapSink, mapStream,
    mapMaybeStream, concatMapStream,
    mapStreamChunks, mapAccumStreamChunks, foldStream, mapAccumStream, concatMapAccumStream, partitionStream,
    -- *** Monadic stream transformations
    mapMStream, mapMStream_, mapMStreamChunks_,
    filterMStream, foldMStream, foldMStream_, unfoldMStream, unmapMStream_, unmapMStreamChunks_,
    zipWithMStream, parZipWithMStream,
   )
where

import Prelude hiding (foldl, foldr, map, mapM, mapM_, null, span, takeWhile)

import qualified Control.Monad
import Control.Monad (liftM, when, unless, foldM)
import Data.Functor.Identity (Identity(..))
import Data.Functor.Sum (Sum(InR))
import Data.Monoid (Monoid(mappend, mconcat, mempty), First(First, getFirst))
import Data.Monoid.Factorial (FactorialMonoid)
import qualified Data.Monoid.Factorial as Factorial
import Data.Monoid.Null (MonoidNull(null))
import Data.Maybe (mapMaybe)
import Data.List (mapAccumL)
import qualified Data.List as List (map, span)
import Text.ParserCombinators.Incremental (Parser, feed, feedEof, inspect, completeResults)

import Control.Monad.Parallel (MonadParallel(..))
import Control.Monad.Coroutine
import Control.Monad.Coroutine.SuspensionFunctors (Request, request,
                                                   ReadRequest, requestRead,
                                                   Reader, Reading(..), ReadingResult(..),
                                                   weaveNestedReadWriteRequests)
import Control.Monad.Coroutine.Nested (AncestorFunctor(..), liftAncestor)

type SourceFunctor a x = Sum a (ReadRequest x)
type SinkFunctor a x = Sum a (Request x x)

-- | A 'Sink' can be used to yield output from any nested `Coroutine` computation whose functor provably descends from
-- the functor /a/. It's the write-only end of a communication channel created by 'pipe'.
newtype Sink (m :: * -> *) a x =
   Sink
   {
   -- | This method puts a portion of the producer's output into the `Sink`. The intervening 'Coroutine' computations
   -- suspend up to the 'pipe' invocation that has created the argument sink. The method returns the suffix of the
   -- argument that could not make it into the sink because of the sibling coroutine's death.
   putChunk :: forall d. AncestorFunctor a d => x -> Coroutine d m x
   }

-- | A 'Source' can be used to read input into any nested `Coroutine` computation whose functor provably descends from
-- the functor /a/. It's the read-only end of a communication channel created by 'pipe'.
newtype Source (m :: * -> *) a x =
   Source
   {
   -- | This method consumes a portion of input from the 'Source' using the 'Reader' argument and returns the
   -- 'ReadingResult'. Depending on the reader, the producer coroutine may not need to be resumed at all, or it may need
   -- to be resumed many times. The intervening 'Coroutine' computations suspend all the way to the 'pipe' function
   -- invocation that created the source.
   readChunk :: forall d py y. AncestorFunctor a d => Reader x py y -> Coroutine d m (ReadingResult x py y)
   }

readAll :: Reader x x x
readAll s = Advance readAll s s

-- | A disconnected sink that consumes and ignores all data 'put' into it.
nullSink :: forall m a x. (Monad m, Monoid x) => Sink m a x
nullSink = Sink{putChunk= const (return mempty)}

-- | A disconnected sink that consumes and ignores all data 'put' into it.
emptySource :: forall m a x. (Monad m, Monoid x) => Source m a x
emptySource = Source{readChunk= return . finalize . ($ mempty)}
   where finalize (Final _ x) = FinalResult x
         finalize (Advance _ x _) = FinalResult x
         finalize (Deferred _ x) = FinalResult x

-- | Converts a 'Sink' on the ancestor functor /a/ into a sink on the descendant functor /d/.
liftSink :: forall m a d x. (Monad m, AncestorFunctor a d) => Sink m a x -> Sink m d x
liftSink s = Sink {putChunk= liftAncestor . (putChunk s :: x -> Coroutine d m x)}
{-# INLINE liftSink #-}

-- | Converts a 'Source' on the ancestor functor /a/ into a source on the descendant functor /d/.
liftSource :: forall m a d x. (Monad m, AncestorFunctor a d) => Source m a x -> Source m d x
liftSource s = Source {readChunk= liftAncestor . (readChunk s :: Reader x py y -> Coroutine d m (ReadingResult x py y))}
{-# INLINE liftSource #-}

-- | A sink mark-up transformation: every chunk going into the sink is accompanied by the given value.
markUpWith :: forall m a x mark. (Monad m, Monoid x) => mark -> Sink m a [(x, mark)] -> Sink m a x
markUpWith mark sink = Sink putMarkedChunk
   where putMarkedChunk :: forall d. AncestorFunctor a d => x -> Coroutine d m x
         putMarkedChunk x = do rest <- putChunk sink [(x, mark)]
                               case rest of [] -> return mempty
                                            [(y, _)]-> return y

-- | A sink mark-down transformation: the marks get removed off each chunk.
markDown :: forall m a x mark. (Monad m, MonoidNull x) => Sink m a x -> Sink m a [(x, mark)]
markDown sink = Sink putUnmarkedChunk
   where putUnmarkedChunk :: forall d. AncestorFunctor a d => [(x, mark)] -> Coroutine d m [(x, mark)]
         putUnmarkedChunk [] = return mempty
         putUnmarkedChunk ((x, mark):tail) = do rest <- putChunk sink x
                                                if null rest 
                                                   then putUnmarkedChunk tail
                                                   else return ((rest, mark):tail)

-- | The 'pipe' function splits the computation into two concurrent parts, /producer/ and /consumer/. The /producer/ is
-- given a 'Sink' to put values into, and /consumer/ a 'Source' to get those values from. Once producer and consumer
-- both complete, 'pipe' returns their paired results.
pipe :: forall m a a1 a2 x r1 r2. (Monad m, Monoid x, Functor a, a1 ~ SinkFunctor a x, a2 ~ SourceFunctor a x) =>
        (Sink m a1 x -> Coroutine a1 m r1) -> (Source m a2 x -> Coroutine a2 m r2) -> Coroutine a m (r1, r2)
pipe = pipeG sequentialBinder

-- | The 'pipeP' function is equivalent to 'pipe', except it runs the /producer/ and the /consumer/ in parallel.
pipeP :: forall m a a1 a2 x r1 r2. 
         (MonadParallel m, Monoid x, Functor a, a1 ~ SinkFunctor a x, a2 ~ SourceFunctor a x) =>
         (Sink m a1 x -> Coroutine a1 m r1) -> (Source m a2 x -> Coroutine a2 m r2) -> Coroutine a m (r1, r2)
pipeP = pipeG bindM2

-- | A generic version of 'pipe'. The first argument is used to combine two computation steps.
pipeG :: forall m a a1 a2 x r1 r2. (Monad m, Monoid x, Functor a, a1 ~ SinkFunctor a x, a2 ~ SourceFunctor a x) =>
         PairBinder m -> (Sink m a1 x -> Coroutine a1 m r1) -> (Source m a2 x -> Coroutine a2 m r2)
      -> Coroutine a m (r1, r2)
pipeG run2 producer consumer =
   liftM (uncurry (flip (,))) $
   weave run2 weaveNestedReadWriteRequests (consumer source) (producer sink)
   where sink = Sink {putChunk= \xs-> liftAncestor (mapSuspension InR (request xs) :: Coroutine a1 m x)}
         source = Source {readChunk= fc}
         fc :: forall d py y. AncestorFunctor a2 d => Reader x py y -> Coroutine d m (ReadingResult x py y)
         fc t = liftAncestor (mapSuspension InR (requestRead t) :: Coroutine a2 m (ReadingResult x py y))

fromParser :: forall p x y. Monoid x => y -> Parser p x y -> Reader x (y -> y) y
fromParser failure p s = case inspect (feed s p)
                         of ([], Nothing) -> Final s failure
                            ([], Just (Nothing, p')) -> Deferred (fromParser failure p') r'
                               where (r', s') = case completeResults (feedEof p')
                                                of [] -> (failure, s)
                                                   hd:_ -> hd
                            ([], Just (Just prefix, p')) -> Advance (fromParser failure p') (prefix r') prefix
                               where (r', s'):_ = completeResults (feedEof p')
                            ([(r, s')], Nothing) -> Final s' r

-- | Function 'get' tries to get a single value from the given 'Source' argument. The intervening 'Coroutine'
-- computations suspend all the way to the 'pipe' function invocation that created the source. The function returns
-- 'Nothing' if the argument source is empty.
get :: forall m a d x. (Monad m, AncestorFunctor a d) => Source m a [x] -> Coroutine d m (Maybe x)
get source = readChunk source readOne
              >>= \(FinalResult x) -> return x
   where readOne [] = Deferred readOne Nothing
         readOne (x:rest) = Final rest (Just x)

-- | Tries to get a minimal, /i.e./, prime, prefix from the given 'Source' argument. The intervening 'Coroutine'
-- computations suspend all the way to the 'pipe' function invocation that created the source. The function returns
-- 'mempty' if the argument source is empty.
getPrime :: forall m a d x. (Monad m, FactorialMonoid x, AncestorFunctor a d) => Source m a x -> Coroutine d m x
getPrime source = readChunk source primeReader
                  >>= \(FinalResult x) -> return x
   where primeReader x = maybe (Deferred primeReader x) 
                               (\(prefix, rest)-> Final rest prefix) 
                               (Factorial.splitPrimePrefix x)

-- | Invokes its first argument with the value it gets from the source, if there is any to get.
getWith :: forall m a d x. (Monad m, FactorialMonoid x, AncestorFunctor a d) =>
           Source m a x -> (x -> Coroutine d m ()) -> Coroutine d m ()
getWith source consumer = readChunk source primeReader
                          >>= \(FinalResult x) -> x
   where primeReader x = maybe (Deferred primeReader (return ()))
                               (\(prefix, rest)-> Final rest (consumer prefix) )
                               (Factorial.splitPrimePrefix x)

-- | Function 'peek' acts the same way as 'get', but doesn't actually consume the value from the source; sequential
-- calls to 'peek' will always return the same value.
peek :: forall m a d x. (Monad m, AncestorFunctor a d) => Source m a [x] -> Coroutine d m (Maybe x)
peek source = readChunk source readOneAhead
              >>= \(FinalResult x) -> return x
   where readOneAhead [] = Deferred readOneAhead Nothing
         readOneAhead s@(x:_) = Final s (Just x)

-- | 'getAll' consumes and returns all data generated by the source.
getAll :: forall m a d x. (Monad m, Monoid x, AncestorFunctor a d) => Source m a x -> Coroutine d m x
getAll source = readChunk source (readAll id)
                >>= \(FinalResult all)-> return all
   where readAll :: (x -> x) -> Reader x () x
         readAll prefix s = Deferred (readAll (prefix . mappend s)) (prefix s)

-- | Consumes inputs from the /source/ as long as the /parser/ accepts it.
getParsed :: forall m a d p x y. (Monad m, Monoid x, Monoid y, AncestorFunctor a d) => 
             Parser p x y -> Source m a x -> Coroutine d m y
getParsed parser = getRead (fromParser mempty parser)

-- | Consumes input from the /source/ as long as the /reader/ accepts it.
getRead :: forall m a d x y. (Monad m, Monoid x, AncestorFunctor a d) => 
           Reader x (y -> y) y -> Source m a x -> Coroutine d m y
getRead reader source = loop return reader
   where loop cont r = readChunk source r >>= proceed cont
         proceed cont (FinalResult chunk) = cont chunk
         proceed cont (ResultPart d p') = loop (cont . d) p'

-- | Consumes values from the /source/ as long as each satisfies the predicate, then returns their list.
getWhile :: forall m a d x. (Monad m, FactorialMonoid x, AncestorFunctor a d) =>
            (x -> Bool) -> Source m a x -> Coroutine d m x
getWhile predicate source = readChunk source (readWhile predicate id)
                            >>= \(FinalResult x)-> return x
   where readWhile :: (x -> Bool) -> (x -> x) -> Reader x () x
         readWhile predicate prefix1 s = if null suffix
                                         then Deferred (readWhile predicate (prefix1 . mappend s)) (prefix1 s)
                                         else Final suffix (prefix1 prefix2)
            where (prefix2, suffix) = Factorial.span predicate s

-- | Consumes values from the /source/ until one of them satisfies the predicate or the source is emptied, then returns
-- the pair of the list of preceding values and maybe the one value that satisfied the predicate. The latter is not
-- consumed.
getUntil :: forall m a d x. (Monad m, FactorialMonoid x, AncestorFunctor a d) =>
            (x -> Bool) -> Source m a x -> Coroutine d m (x, Maybe x)
getUntil predicate source = readChunk source (readUntil (not . predicate) id)
                            >>= \(FinalResult r)-> return r
   where readUntil :: (x -> Bool) -> (x -> x) -> Reader x () (x, Maybe x)
         readUntil predicate prefix1 s = if null suffix
                                         then Deferred (readUntil predicate (prefix1 . mappend s)) (prefix1 s, Nothing)
                                         else Final suffix (prefix1 prefix2, Just $ Factorial.primePrefix suffix)
            where (prefix2, suffix) = Factorial.span predicate s

-- | Copies all data from the /source/ argument into the /sink/ argument. The result indicates if there was any chunk to
-- copy.
pour :: forall m a1 a2 d x . (Monad m, Monoid x, AncestorFunctor a1 d, AncestorFunctor a2 d)
        => Source m a1 x -> Sink m a2 x -> Coroutine d m Bool
pour source sink = loop False
   where loop another = readChunk source readAll >>= extract another
         extract another (FinalResult _chunk) = return another -- the last chunk must be empty
         extract _ (ResultPart chunk _) = putChunk sink chunk >> loop True

-- | Copies all data from the /source/ argument into the /sink/ argument, like 'pour' but ignoring the result.
pour_ :: forall m a1 a2 d x . (Monad m, Monoid x, AncestorFunctor a1 d, AncestorFunctor a2 d)
        => Source m a1 x -> Sink m a2 x -> Coroutine d m ()
pour_ source sink = pour source sink >> return ()

-- | Like 'pour', copies data from the /source/ to the /sink/, but only as long as it satisfies the predicate.
pourRead :: forall m a1 a2 d x y. (Monad m, MonoidNull x, MonoidNull y, AncestorFunctor a1 d, AncestorFunctor a2 d)
              => Reader x y y -> Source m a1 x -> Sink m a2 y -> Coroutine d m ()
pourRead reader source sink = loop reader
   where loop p = readChunk source p >>= extract
         extract (FinalResult r) = unless (null r) (putChunk sink r >> return ())
         extract (ResultPart chunk p') = putChunk sink chunk >> loop p'

-- | Parses the input data using the given parser and copies the results to output.
pourParsed :: forall m p a1 a2 d x y. (Monad m, MonoidNull x, MonoidNull y, AncestorFunctor a1 d, AncestorFunctor a2 d)
              => Parser p x y -> Source m a1 x -> Sink m a2 y -> Coroutine d m ()
pourParsed parser source sink = loop (fromParser mempty parser)
   where loop p = readChunk source p >>= extract
         extract (FinalResult r) = unless (null r) (putChunk sink r >> return ())
         extract (ResultPart d p') = putChunk sink (d mempty) >> loop p'

-- | Like 'pour', copies data from the /source/ to the /sink/, but only as long as it satisfies the predicate.
pourWhile :: forall m a1 a2 d x . (Monad m, FactorialMonoid x, AncestorFunctor a1 d, AncestorFunctor a2 d)
             => (x -> Bool) -> Source m a1 x -> Sink m a2 x -> Coroutine d m ()
pourWhile = pourRead . readWhile
   where readWhile :: FactorialMonoid x => (x -> Bool) -> Reader x x x
         readWhile p = while
            where while s = if null suffix
                            then Advance while prefix prefix
                            else Final suffix prefix
                     where (prefix, suffix) = Factorial.span p s

-- | Like 'pour', copies data from the /source/ to the /sink/, but only until one value satisfies the predicate. That
-- value is returned rather than copied.
pourUntil :: forall m a1 a2 d x . (Monad m, FactorialMonoid x, AncestorFunctor a1 d, AncestorFunctor a2 d)
             => (x -> Bool) -> Source m a1 x -> Sink m a2 x -> Coroutine d m (Maybe x)
pourUntil predicate source sink = loop $ readUntil (not . predicate)
   where readUntil :: FactorialMonoid x => (x -> Bool) -> Reader x x (x, Maybe x)
         readUntil p = until
            where until s = if null suffix
                            then Advance until (prefix, Nothing) prefix
                            else Final suffix (prefix, Just $ Factorial.primePrefix suffix)
                     where (prefix, suffix) = Factorial.span p s
         loop rd = readChunk source rd >>= extract
         extract (FinalResult (chunk, mx)) = putChunk sink chunk >> return mx
         extract (ResultPart chunk rd') = putChunk sink chunk >> loop rd'

-- | 'mapStream' is like 'pour' that applies the function /f/ to each argument before passing it into the /sink/.
mapStream :: forall m a1 a2 d x y . (Monad m, FactorialMonoid x, Monoid y, AncestorFunctor a1 d, AncestorFunctor a2 d)
           => (x -> y) -> Source m a1 x -> Sink m a2 y -> Coroutine d m ()
mapStream f source sink = loop
   where loop = readChunk source readAll
                >>= \r-> case r
                         of ResultPart chunk _ -> putChunk sink (Factorial.foldMap f chunk) >> loop
                            FinalResult _ -> return ()  -- the last chunk must be empty

-- | An equivalent of 'Data.List.map' that works on a 'Sink' instead of a list. The argument function is applied to
-- every value vefore it's written to the sink argument.
mapSink :: forall m a x y. Monad m => (x -> y) -> Sink m a [y] -> Sink m a [x]
mapSink f sink = Sink{putChunk= \xs-> putChunk sink (List.map f xs)
                                      >>= \rest-> return (dropExcept (length rest) xs)}
   where dropExcept :: forall z. Int -> [z] -> [z]
         dropExcept 0 _ = []
         dropExcept n list = snd (drop' list)
            where drop' :: [z] -> (Int, [z])
                  drop' [] = (0, [])
                  drop' (x:xs) = let r@(len, tl) = drop' xs in if len < n then (succ len, x:tl) else r
         

-- | 'mapMaybeStream' is to 'mapStream' like 'Data.Maybe.mapMaybe' is to 'Data.List.map'.
mapMaybeStream :: forall m a1 a2 d x y . (Monad m, AncestorFunctor a1 d, AncestorFunctor a2 d)
                => (x -> Maybe y) -> Source m a1 [x] -> Sink m a2 [y] -> Coroutine d m ()
mapMaybeStream f source sink = mapMStreamChunks_ ((>> return ()) . putChunk sink . mapMaybe f) source

-- | 'concatMapStream' is to 'mapStream' like 'Data.List.concatMap' is to 'Data.List.map'.
concatMapStream :: forall m a1 a2 d x y . (Monad m, Monoid y, AncestorFunctor a1 d, AncestorFunctor a2 d)
                   => (x -> y) -> Source m a1 [x] -> Sink m a2 y -> Coroutine d m ()
concatMapStream f = mapStream (mconcat . List.map f)

-- | 'mapAccumStream' is similar to 'mapAccumL' except it reads the values from a 'Source' instead of a list
-- and writes the mapped values into a 'Sink' instead of returning another list.
mapAccumStream :: forall m a1 a2 d x y acc . (Monad m, AncestorFunctor a1 d, AncestorFunctor a2 d)
                  => (acc -> x -> (acc, y)) -> acc -> Source m a1 [x] -> Sink m a2 [y] -> Coroutine d m acc
mapAccumStream f acc source sink = foldMStreamChunks (\a xs-> dispatch $ mapAccumL f a xs) acc source
   where dispatch (a, ys) = putChunk sink ys >> return a

-- | 'concatMapAccumStream' is a love child of 'concatMapStream' and 'mapAccumStream': it threads the accumulator like
-- the latter, but its argument function returns not a single value, but a list of values to write into the sink.
concatMapAccumStream :: forall m a1 a2 d x y acc . (Monad m, AncestorFunctor a1 d, AncestorFunctor a2 d)
                  => (acc -> x -> (acc, [y])) -> acc -> Source m a1 [x] -> Sink m a2 [y] -> Coroutine d m acc
concatMapAccumStream f acc source sink = foldMStreamChunks (\a xs-> dispatch $ concatMapAccumL a xs) acc source
   where dispatch (a, ys) = putChunk sink ys >> return a
         concatMapAccumL s []        =  (s, [])
         concatMapAccumL s (x:xs)    =  (s'', y ++ ys)
            where (s',  y ) = f s x
                  (s'', ys) = concatMapAccumL s' xs

-- | Like 'mapStream' except it runs the argument function on whole chunks read from the input.
mapStreamChunks :: forall m a1 a2 d x y . (Monad m, Monoid x, AncestorFunctor a1 d, AncestorFunctor a2 d)
                   => (x -> y) -> Source m a1 x -> Sink m a2 y -> Coroutine d m ()
mapStreamChunks f source sink = loop
   where loop = readChunk source readAll
                >>= \r-> case r
                         of ResultPart chunk _ -> putChunk sink (f chunk) >> loop
                            FinalResult _ -> return ()  -- the last chunk must be empty

-- | Like 'mapAccumStream' except it runs the argument function on whole chunks read from the input.
mapAccumStreamChunks :: forall m a1 a2 d x y acc. (Monad m, Monoid x, AncestorFunctor a1 d, AncestorFunctor a2 d)
                   => (acc -> x -> (acc, y)) -> acc -> Source m a1 x -> Sink m a2 y -> Coroutine d m acc
mapAccumStreamChunks f acc source sink = loop acc
   where loop acc = readChunk source readAll
                    >>= \r-> case r
                             of ResultPart chunk _ -> let (acc', chunk') = f acc chunk 
                                                      in putChunk sink chunk' >> loop acc'
                                FinalResult _ -> return acc  -- the last chunk must be empty

-- | 'mapMStream' is similar to 'Control.Monad.mapM'. It draws the values from a 'Source' instead of a list, writes the
-- mapped values to a 'Sink', and returns a 'Coroutine'.
mapMStream :: forall m a1 a2 d x y . (Monad m, FactorialMonoid x, Monoid y, AncestorFunctor a1 d, AncestorFunctor a2 d)
              => (x -> Coroutine d m y) -> Source m a1 x -> Sink m a2 y -> Coroutine d m ()
mapMStream f source sink = loop
   where loop = readChunk source readAll
                >>= \r-> case r
                         of ResultPart chunk _ -> Factorial.mapM f chunk >>= putChunk sink >> loop
                            FinalResult _ -> return ()  -- the last chunk must be empty

-- | 'mapMStream_' is similar to 'Control.Monad.mapM_' except it draws the values from a 'Source' instead of a list and
-- works with 'Coroutine' instead of an arbitrary monad.
mapMStream_ :: forall m a d x r. (Monad m, FactorialMonoid x, AncestorFunctor a d)
              => (x -> Coroutine d m r) -> Source m a x -> Coroutine d m ()
mapMStream_ f = mapMStreamChunks_ (Factorial.mapM_ f)

-- | Like 'mapMStream_' except it runs the argument function on whole chunks read from the input.
mapMStreamChunks_ :: forall m a d x r. (Monad m, Monoid x, AncestorFunctor a d)
              => (x -> Coroutine d m r) -> Source m a x -> Coroutine d m ()
mapMStreamChunks_ f source = loop
   where loop = readChunk source readAll
                >>= \r-> case r
                         of ResultPart chunk _ -> f chunk >> loop
                            FinalResult _ -> return ()  -- the last chunk must be empty

-- | An equivalent of 'Control.Monad.filterM'. Draws the values from a 'Source' instead of a list, writes the filtered
-- values to a 'Sink', and returns a 'Coroutine'.
filterMStream :: forall m a1 a2 d x . (Monad m, FactorialMonoid x, AncestorFunctor a1 d, AncestorFunctor a2 d)
              => (x -> Coroutine d m Bool) -> Source m a1 x -> Sink m a2 x -> Coroutine d m ()
filterMStream f = mapMStream (\x-> f x >>= \p-> return $ if p then x else mempty)

-- | Similar to 'Data.List.foldl', but reads the values from a 'Source' instead of a list.
foldStream :: forall m a d x acc . (Monad m, FactorialMonoid x, AncestorFunctor a d)
              => (acc -> x -> acc) -> acc -> Source m a x -> Coroutine d m acc
foldStream f acc source = loop acc
   where loop a = readChunk source readAll
                  >>= \r-> case r
                           of ResultPart chunk _ -> loop (Factorial.foldl f a chunk)
                              FinalResult{} -> return a  -- the last chunk must be empty

-- | 'foldMStream' is similar to 'Control.Monad.foldM' except it draws the values from a 'Source' instead of a list and
-- works with 'Coroutine' instead of an arbitrary monad.
foldMStream :: forall m a d x acc . (Monad m, AncestorFunctor a d)
              => (acc -> x -> Coroutine d m acc) -> acc -> Source m a [x] -> Coroutine d m acc
foldMStream f acc source = loop acc
   where loop a = readChunk source readAll
                  >>= \r-> case r
                           of ResultPart chunk _ -> foldM f a chunk >>= loop
                              FinalResult [] -> return a  -- the last chunk must be empty

-- | A variant of 'foldMStream' that discards the final result value.
foldMStream_ :: forall m a d x acc . (Monad m, AncestorFunctor a d)
                => (acc -> x -> Coroutine d m acc) -> acc -> Source m a [x] -> Coroutine d m ()
foldMStream_ f acc source = foldMStream f acc source >> return ()

-- | Like 'foldMStream' but working on whole chunks from the argument source.
foldMStreamChunks :: forall m a d x acc . (Monad m, Monoid x, AncestorFunctor a d)
                     => (acc -> x -> Coroutine d m acc) -> acc -> Source m a x -> Coroutine d m acc
foldMStreamChunks f acc source = loop acc
   where loop a = readChunk source readAll
                  >>= \r-> case r
                           of ResultPart chunk _ -> f a chunk >>= loop
                              FinalResult _ -> return a  -- the last chunk must be empty

-- | 'unfoldMStream' is a version of 'Data.List.unfoldr' that writes the generated values into a 'Sink' instead of
-- returning a list.
unfoldMStream :: forall m a d x acc . (Monad m, AncestorFunctor a d)
                 => (acc -> Coroutine d m (Maybe (x, acc))) -> acc -> Sink m a [x] -> Coroutine d m acc
unfoldMStream f acc sink = loop acc
   where loop a = f a >>= maybe (return a) (\(x, acc')-> put sink x >> loop acc')

-- | 'unmapMStream_' is opposite of 'mapMStream_'; it takes a 'Sink' instead of a 'Source' argument and writes the
-- generated values into it.
unmapMStream_ :: forall m a d x . (Monad m, AncestorFunctor a d)
                 => Coroutine d m (Maybe x) -> Sink m a [x] -> Coroutine d m ()
unmapMStream_ f sink = loop
   where loop = f >>= maybe (return ()) (\x-> put sink x >> loop)

-- | Like 'unmapMStream_' but writing whole chunks of generated data into the argument sink.
unmapMStreamChunks_ :: forall m a d x . (Monad m, MonoidNull x, AncestorFunctor a d)
                       => Coroutine d m x -> Sink m a x -> Coroutine d m ()
unmapMStreamChunks_ f sink = loop >> return ()
   where loop = f >>= nullOrElse (return mempty) ((>>= nullOrElse loop return) . putChunk sink)

-- | Equivalent to 'Data.List.partition'. Takes a 'Source' instead of a list argument and partitions its contents into
-- the two 'Sink' arguments.
partitionStream :: forall m a1 a2 a3 d x . (Monad m, AncestorFunctor a1 d, AncestorFunctor a2 d, AncestorFunctor a3 d)
                   => (x -> Bool) -> Source m a1 [x] -> Sink m a2 [x] -> Sink m a3 [x] -> Coroutine d m ()
partitionStream f source true false = mapMStreamChunks_ partitionChunk source
   where partitionChunk (x:rest) = partitionTo (f x) x rest
         partitionChunk [] = return ()
         partitionTo False x chunk = let (falses, rest) = break f chunk
                                     in putChunk false (x:falses)
                                        >> case rest of y:ys -> partitionTo True y ys
                                                        [] -> return ()
         partitionTo True x chunk = let (trues, rest) = List.span f chunk
                                    in putChunk true (x:trues)
                                       >> case rest of y:ys -> partitionTo False y ys
                                                       [] -> return ()

-- | 'zipWithMStream' is similar to 'Control.Monad.zipWithM' except it draws the values from two 'Source' arguments
-- instead of two lists, sends the results into a 'Sink', and works with 'Coroutine' instead of an arbitrary monad.
zipWithMStream :: forall m a1 a2 a3 d x y z. (Monad m, AncestorFunctor a1 d, AncestorFunctor a2 d, AncestorFunctor a3 d)
                  => (x -> y -> Coroutine d m z) -> Source m a1 [x] -> Source m a2 [y] -> Sink m a3 [z]
                  -> Coroutine d m ()
zipWithMStream f source1 source2 sink = loop
   where loop = do mx <- get source1
                   my <- get source2
                   case (mx, my) of (Just x, Just y) -> f x y >>= put sink >> loop
                                    _ -> return ()

-- | 'parZipWithMStream' is equivalent to 'zipWithMStream', but it consumes the two sources in parallel.
parZipWithMStream :: forall m a1 a2 a3 d x y z.
                     (MonadParallel m, AncestorFunctor a1 d, AncestorFunctor a2 d, AncestorFunctor a3 d)
                     => (x -> y -> Coroutine d m z) -> Source m a1 [x] -> Source m a2 [y] -> Sink m a3 [z]
                     -> Coroutine d m ()
parZipWithMStream f source1 source2 sink = loop
   where loop = bindM2 zipMaybe (get source1) (get source2)
         zipMaybe (Just x) (Just y) = f x y >>= put sink >> loop
         zipMaybe _ _ = return ()

-- | 'tee' is similar to 'pour' except it distributes every input value from its source argument into its both sink
-- arguments.
tee :: forall m a1 a2 a3 d x . (Monad m, Monoid x, AncestorFunctor a1 d, AncestorFunctor a2 d, AncestorFunctor a3 d)
       => Source m a1 x -> Sink m a2 x -> Sink m a3 x -> Coroutine d m ()
tee source sink1 sink2 = distribute
   where distribute = readChunk source readAll
                      >>= \r-> case r
                               of ResultPart chunk _ -> putChunk sink1 chunk >> putChunk sink2 chunk >> distribute
                                  FinalResult _ -> return ()  -- the last chunk must be empty

-- | Every value 'put' into a 'teeSink' result sink goes into its both argument sinks: @put (teeSink s1 s2) x@ is
-- equivalent to @put s1 x >> put s2 x@. The 'putChunk' method returns the list of values that couldn't fit into the
-- second sink.
teeSink :: forall m a1 a2 a3 x . (Monad m, AncestorFunctor a1 a3, AncestorFunctor a2 a3)
           => Sink m a1 x -> Sink m a2 x -> Sink m a3 x
teeSink s1 s2 = Sink{putChunk= teeChunk}
   where teeChunk :: forall d. AncestorFunctor a3 d => x -> Coroutine d m x
         teeChunk x = putChunk s1' x >> putChunk s2' x
         s1' :: Sink m a3 x
         s1' = liftSink s1
         s2' :: Sink m a3 x
         s2' = liftSink s2

-- | This function puts a value into the given `Sink`. The intervening 'Coroutine' computations suspend up
-- to the 'pipe' invocation that has created the argument sink.
put :: forall m a d x. (Monad m, AncestorFunctor a d) => Sink m a [x] -> x -> Coroutine d m ()
put sink x = putChunk sink [x] >> return ()

-- | Like 'put', but returns a Bool that determines if the sink is still active.
tryPut :: forall m a d x. (Monad m, AncestorFunctor a d) => Sink m a [x] -> x -> Coroutine d m Bool
tryPut sink x = liftM null $ putChunk sink [x]

-- | 'putAll' puts an entire list into its /sink/ argument. If the coroutine fed by the /sink/ dies, the remainder of
-- the argument list is returned.
putAll :: forall m a d x. (Monad m, MonoidNull x, AncestorFunctor a d) => x -> Sink m a x -> Coroutine d m x
putAll l sink = if null l then return l else putChunk sink l

nullOrElse :: MonoidNull x => a -> (x -> a) -> x -> a
nullOrElse nullCase f x | null x = nullCase
                        | otherwise = f x
