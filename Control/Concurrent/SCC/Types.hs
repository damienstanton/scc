{- 
    Copyright 2009-2016 Mario Blazevic

    This file is part of the Streaming Component Combinators (SCC) project.

    The SCC project is free software: you can redistribute it and/or modify it under the terms of the GNU General Public
    License as published by the Free Software Foundation, either version 3 of the License, or (at your option) any later
    version.

    SCC is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY; without even the implied warranty
    of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU General Public License for more details.

    You should have received a copy of the GNU General Public License along with SCC.  If not, see
    <http://www.gnu.org/licenses/>.
-}

-- | This module defines various 'Control.Concurrent.SCC.Coroutine' types that operate on
-- 'Control.Concurrent.SCC.Streams.Sink' and 'Control.Concurrent.SCC.Streams.Source' values. The simplest of the bunch
-- are 'Consumer' and 'Producer' types, which respectively operate on a single source or sink. A 'Transducer' has access
-- both to a 'Control.Concurrent.SCC.Streams.Source' to read from and a 'Control.Concurrent.SCC.Streams.Sink' to write
-- into. Finally, a 'Splitter' reads from a single source and writes all of the input, without any modifications, into
-- two sinks of the same type.
-- 

{-# LANGUAGE ScopedTypeVariables, KindSignatures, RankNTypes,
             MultiParamTypeClasses, FlexibleContexts, FlexibleInstances,
             FunctionalDependencies, TypeFamilies #-}

module Control.Concurrent.SCC.Types (
   -- * Component types
   Performer(..),
   OpenConsumer, Consumer(..), OpenProducer, Producer(..),
   OpenTransducer, Transducer(..), OpenSplitter, Splitter(..),
   Boundary(..), Markup(..), Parser,
   PipeableComponentPair (compose), Branching (combineBranches),
   -- * Component constructors
   isolateConsumer, isolateProducer, isolateTransducer, isolateSplitter,
   oneToOneTransducer, statelessTransducer, statelessChunkTransducer, statefulTransducer,
   statelessSplitter, statefulSplitter,
   )
where

import Control.Category (Category(id), (>>>))
import qualified Control.Category as Category
import Control.Monad (liftM)
import Data.Monoid (Monoid(..))

import Control.Monad.Coroutine
import Data.Monoid.Null (MonoidNull)
import Data.Monoid.Factorial (FactorialMonoid)

import Control.Concurrent.SCC.Streams

type OpenConsumer m a d x r = (AncestorFunctor a d, Monoid x) => Source m a x -> Coroutine d m r
type OpenProducer m a d x r = (AncestorFunctor a d, Monoid x) => Sink m a x -> Coroutine d m r
type OpenTransducer m a1 a2 d x y r = 
   (AncestorFunctor a1 d, AncestorFunctor a2 d, Monoid x, Monoid y) => Source m a1 x -> Sink m a2 y -> Coroutine d m r
type OpenSplitter m a1 a2 a3 d x r =
   (AncestorFunctor a1 d, AncestorFunctor a2 d, AncestorFunctor a3 d, Monoid x) =>
   Source m a1 x -> Sink m a2 x -> Sink m a3 x -> Coroutine d m r

-- | A coroutine that has no inputs nor outputs - and therefore may not suspend at all, which means it's not really a
-- /co/routine.
newtype Performer m r = Performer {perform :: m r}

-- | A coroutine that consumes values from a 'Control.Concurrent.SCC.Streams.Source'.
newtype Consumer m x r = Consumer {consume :: forall a d. OpenConsumer m a d x r}

-- | A coroutine that produces values and puts them into a 'Control.Concurrent.SCC.Streams.Sink'.
newtype Producer m x r = Producer {produce :: forall a d. OpenProducer m a d x r}

-- | The 'Transducer' type represents coroutines that transform a data stream.  Execution of 'transduce' must continue
-- consuming the given 'Control.Concurrent.SCC.Streams.Source' and feeding the 'Control.Concurrent.SCC.Streams.Sink' as
-- long as there is any data in the source.
newtype Transducer m x y = Transducer {transduce :: forall a1 a2 d. OpenTransducer m a1 a2 d x y ()}

-- | The 'Splitter' type represents coroutines that distribute the input stream acording to some criteria. A splitter
-- should distribute only the original input data, and feed it into the sinks in the same order it has been read from
-- the source. Furthermore, the input source should be entirely consumed and fed into the two sinks.
-- 
-- A splitter can be used in two ways: as a predicate to determine which portions of its input stream satisfy a certain
-- property, or as a chunker to divide the input stream into chunks. In the former case, the predicate is considered
-- true for exactly those parts of the input that are written to its /true/ sink. In the latter case, a chunk is a
-- contiguous section of the input stream that is written exclusively to one sink, either true or false. A 'mempty'
-- value written to either of the two sinks can also terminate the chunk written to the other sink.
newtype Splitter m x = Splitter {split :: forall a1 a2 a3 d. OpenSplitter m a1 a2 a3 d x ()}

-- | A 'Boundary' value is produced to mark either a 'Start' and 'End' of a region of data, or an arbitrary 'Point' in
-- data. A 'Point' is semantically equivalent to a 'Start' immediately followed by 'End'.
data Boundary y = Start y | End y | Point y deriving (Eq, Show)

-- | Type of values in a markup-up stream. The 'Content' constructor wraps the actual data.
data Markup y x = Content x | Markup (Boundary y) deriving (Eq)

-- | A parser is a transducer that marks up its input.
type Parser m x b = Transducer m x [Markup b x]

instance Functor Boundary where
   fmap f (Start b) = Start (f b)
   fmap f (End b) = End (f b)
   fmap f (Point b) = Point (f b)

instance Functor (Markup y) where
   fmap f (Content x) = Content (f x)
   fmap _ (Markup b) = Markup b

instance (Show x , Show y) => Show (Markup y x) where
   showsPrec _ (Content x) s = shows x s
   showsPrec _ (Markup b) s = '[' : shows b (']' : s)

-- instance Monad m => Category (Transducer m) where
--    id = Transducer pour
--    t1 . t2 = isolateTransducer $ \source sink-> 
--              pipe (transduce t2 source) (\source'-> transduce t1 source' sink)
--              >> return ()

-- | Creates a proper 'Consumer' from a function that is, but can't be proven to be, an 'OpenConsumer'.
isolateConsumer :: forall m x r. (Monad m, Monoid x) =>
                   (forall d. Functor d => Source m d x -> Coroutine d m r) -> Consumer m x r
isolateConsumer c = Consumer consume'
   where consume' :: forall a d. OpenConsumer m a d x r
         consume' source = let source' :: Source m d x
                               source' = liftSource source
                           in c source'

-- | Creates a proper 'Producer' from a function that is, but can't be proven to be, an 'OpenProducer'.
isolateProducer :: forall m x r. (Monad m, Monoid x) =>
                   (forall d. Functor d => Sink m d x -> Coroutine d m r) -> Producer m x r
isolateProducer p = Producer produce'
   where produce' :: forall a d. OpenProducer m a d x r
         produce' sink = let sink' :: Sink m d x
                             sink' = liftSink sink
                         in p sink'

-- | Creates a proper 'Transducer' from a function that is, but can't be proven to be, an 'OpenTransducer'.
isolateTransducer :: forall m x y. (Monad m, Monoid x) =>
                     (forall d. Functor d => Source m d x -> Sink m d y -> Coroutine d m ()) -> Transducer m x y
isolateTransducer t = Transducer transduce'
   where transduce' :: forall a1 a2 d. OpenTransducer m a1 a2 d x y ()
         transduce' source sink = let source' :: Source m d x
                                      source' = liftSource source
                                      sink' :: Sink m d y
                                      sink' = liftSink sink
                                  in t source' sink'

-- | Creates a proper 'Splitter' from a function that is, but can't be proven to be, an 'OpenSplitter'.
isolateSplitter :: forall m x b. (Monad m, Monoid x) =>
                   (forall d. Functor d => Source m d x -> Sink m d x -> Sink m d x -> Coroutine d m ())
                   -> Splitter m x
isolateSplitter s = Splitter split'
   where split' :: forall a1 a2 a3 d. OpenSplitter m a1 a2 a3 d x ()
         split' source true false = let source' :: Source m d x
                                        source' = liftSource source
                                        true' :: Sink m d x
                                        true' = liftSink true
                                        false' :: Sink m d x
                                        false' = liftSink false
                                    in s source' true' false'


-- | Class 'PipeableComponentPair' applies to any two components that can be combined into a third component with the
-- following properties:
--
--    * The input of the result, if any, becomes the input of the first component.
--
--    * The output produced by the first child component is consumed by the second child component.
--
--    * The result output, if any, is the output of the second component.
class PipeableComponentPair (m :: * -> *) w c1 c2 c3 | c1 c2 -> c3, c1 c3 -> c2, c2 c3 -> c2,
                                                       c1 -> m w, c2 -> m w, c3 -> m
   where compose :: PairBinder m -> c1 -> c2 -> c3

instance {-# OVERLAPS #-} forall m x. (Monad m, Monoid x) =>
         PipeableComponentPair m x (Producer m x ()) (Consumer m x ()) (Performer m ())
   where compose binder p c = let performPipe :: Coroutine Naught m ((), ())
                                  performPipe = pipeG binder (produce p) (consume c)
                              in Performer (runCoroutine performPipe >> return ())

instance  {-# OVERLAPS #-} forall m x r. (Monad m, Monoid x) =>
         PipeableComponentPair m x (Producer m x ()) (Consumer m x r) (Performer m r)
   where compose binder p c = let performPipe :: Coroutine Naught m ((), r)
                                  performPipe = pipeG binder (produce p) (consume c)
                              in Performer (liftM snd $ runCoroutine performPipe)

instance  {-# OVERLAPS #-} forall m x r. (Monad m, Monoid x) =>
         PipeableComponentPair m x (Producer m x r) (Consumer m x ()) (Performer m r)
   where compose binder p c = let performPipe :: Coroutine Naught m (r, ())
                                  performPipe = pipeG binder (produce p) (consume c)
                              in Performer (liftM fst $ runCoroutine performPipe)

instance (Monad m, Monoid x, Monoid y) => 
         PipeableComponentPair m y (Transducer m x y) (Consumer m y r) (Consumer m x r)
   where compose binder t c = isolateConsumer $ \source-> 
                              liftM snd $
                              pipeG binder
                                 (transduce t source)
                                 (consume c)

instance (Monad m, Monoid x, Monoid y) => 
         PipeableComponentPair m x (Producer m x r) (Transducer m x y) (Producer m y r)
   where compose binder p t = isolateProducer $ \sink-> 
                              liftM fst $
                              pipeG binder
                                 (produce p)
                                 (\source-> transduce t source sink)

instance (Monad m, Monoid x, Monoid y, Monoid z) => 
         PipeableComponentPair m y (Transducer m x y) (Transducer m y z) (Transducer m x z)
   where compose binder t1 t2 = 
            isolateTransducer $ \source sink-> 
            pipeG binder (transduce t1 source) (\source'-> transduce t2 source' sink)
            >> return ()

-- | 'Branching' is a type class representing all types that can act as consumers, namely 'Consumer',
-- 'Transducer', and 'Splitter'.
class Branching c (m :: * -> *) x r | c -> m x where
   -- | 'combineBranches' is used to combine two values of 'Branch' class into one, using the given 'Consumer' binary
   -- combinator.
   combineBranches :: (forall d. (PairBinder m ->
                                  (forall a d'. AncestorFunctor d d' => OpenConsumer m a d' x r) ->
                                  (forall a d'. AncestorFunctor d d' => OpenConsumer m a d' x r) ->
                                  (forall a. OpenConsumer m a d x r))) ->
                      PairBinder m -> c -> c -> c

instance forall m x r. Monad m => Branching (Consumer m x r) m x r where
   combineBranches combinator binder c1 c2 = Consumer $ combinator binder (consume c1) (consume c2)

instance forall m x y. Monad m => Branching (Transducer m x y) m x () where
   combineBranches combinator binder t1 t2
      = let transduce' :: forall a1 a2 d. OpenTransducer m a1 a2 d x y ()
            transduce' source sink = combinator binder
                                        (\source'-> transduce t1 source' sink')
                                        (\source'-> transduce t2 source' sink')
                                        source
               where sink' :: Sink m d y
                     sink' = liftSink sink
        in Transducer transduce'

instance forall m x b. Monad m => Branching (Splitter m x) m x () where
   combineBranches combinator binder s1 s2
      = let split' :: forall a1 a2 a3 d. OpenSplitter m a1 a2 a3 d x ()
            split' source true false = combinator binder
                                          (\source'-> split s1 source' true' false')
                                          (\source'-> split s2 source' true' false')
                                          source
               where true' :: Sink m d x
                     true' = liftSink true
                     false' :: Sink m d x
                     false' = liftSink false
        in Splitter split'

-- | Function 'oneToOneTransducer' takes a function that maps one input value to one output value each, and lifts it
-- into a 'Transducer'.
oneToOneTransducer :: (Monad m, FactorialMonoid x, Monoid y) => (x -> y) -> Transducer m x y
oneToOneTransducer f = Transducer (mapStream f)

-- | Function 'statelessTransducer' takes a function that maps one input value into a list of output values, and
-- lifts it into a 'Transducer'.
statelessTransducer :: Monad m => (x -> y) -> Transducer m [x] y
statelessTransducer f = Transducer (mapStream (mconcat . map f))

-- | Function 'statelessTransducer' takes a function that maps one input value into a list of output values, and
-- lifts it into a 'Transducer'.
statelessChunkTransducer :: Monad m => (x -> y) -> Transducer m x y
statelessChunkTransducer f = Transducer (mapStreamChunks f)

-- | Function 'statefulTransducer' constructs a 'Transducer' from a state-transition function and the initial
-- state. The transition function may produce arbitrary output at any transition step.
statefulTransducer :: (Monad m, MonoidNull y) => (state -> x -> (state, y)) -> state -> Transducer m [x] y
statefulTransducer f s0 = 
   Transducer (\source sink-> foldMStream_ (\ s x -> let (s', ys) = f s x in putAll ys sink >> return s') s0 source)

-- | Function 'statelessSplitter' takes a function that assigns a Boolean value to each input item and lifts it into
-- a 'Splitter'.
statelessSplitter :: Monad m => (x -> Bool) -> Splitter m [x]
statelessSplitter f = Splitter (\source true false-> partitionStream f source true false)

-- | Function 'statefulSplitter' takes a state-converting function that also assigns a Boolean value to each input
-- item and lifts it into a 'Splitter'.
statefulSplitter :: Monad m => (state -> x -> (state, Bool)) -> state -> Splitter m [x]
statefulSplitter f s0 = 
   Splitter (\source true false-> 
              foldMStream_ 
                 (\ s x -> let (s', truth) = f s x in (if truth then put true x else put false x) >> return s')
                 s0 source)
