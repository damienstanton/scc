{-
    Copyright 2008-2016 Mario Blazevic

    This file is part of the Streaming Component Combinators (SCC) project.

    The SCC project is free software: you can redistribute it and/or modify it under the terms of the GNU General Public
    License as published by the Free Software Foundation, either version 3 of the License, or (at your option) any later
    version.

    SCC is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY; without even the implied warranty
    of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU General Public License for more details.

    You should have received a copy of the GNU General Public License along with SCC.  If not, see
    <http://www.gnu.org/licenses/>.
-}

{-# LANGUAGE ScopedTypeVariables, RankNTypes, KindSignatures, EmptyDataDecls,
             MultiParamTypeClasses, FlexibleContexts, FlexibleInstances,
             FunctionalDependencies, TypeFamilies #-}
{-# OPTIONS_HADDOCK hide #-}

-- | The "Combinators" module defines combinators applicable to values of the 'Transducer' and 'Splitter' types defined
-- in the "Control.Concurrent.SCC.Types" module.

module Control.Concurrent.SCC.Combinators (
   -- * Consumer, producer, and transducer combinators
   consumeBy, prepend, append, substitute,
   JoinableComponentPair (join, sequence),
   -- * Splitter combinators
   sNot,
   -- ** Pseudo-logic flow combinators
   -- | Combinators 'sAnd' and 'sOr' are only /pseudo/-logic. While the laws of double negation and De Morgan's laws
   -- hold, 'sAnd' and 'sOr' are in general not commutative, associative, nor idempotent. In the special case when all
   -- argument splitters are stateless, such as those produced by 'Control.Concurrent.SCC.Types.statelessSplitter',
   -- these combinators do satisfy all laws of Boolean algebra.
   sAnd, sOr,
   -- ** Zipping logic combinators
   -- | The 'pAnd' and 'pOr' combinators run the argument splitters in parallel and combine their logical outputs using
   -- the corresponding logical operation on each output pair, in a manner similar to 'Data.List.zipWith'. They fully
   -- satisfy the laws of Boolean algebra.
   pAnd, pOr,
   -- * Flow-control combinators
   -- | The following combinators resemble the common flow-control programming language constructs. Combinators 
   -- 'wherever', 'unless', and 'select' are just the special cases of the combinator 'ifs'.
   --
   --    * /transducer/ ``wherever`` /splitter/ = 'ifs' /splitter/ /transducer/ 'Control.Category.id'
   --
   --    * /transducer/ ``unless`` /splitter/ = 'ifs' /splitter/ 'Control.Category.id' /transducer/
   --
   --    * 'select' /splitter/ = 'ifs' /splitter/ 'Control.Category.id'
   --    'Control.Concurrent.SCC.Primitives.suppress'
   --
   ifs, wherever, unless, select,
   -- ** Recursive
   while, nestedIn,
   -- * Section-based combinators
   -- | All combinators in this section use their 'Control.Concurrent.SCC.Splitter' argument to determine the structure
   -- of the input. Every contiguous portion of the input that gets passed to one or the other sink of the splitter is
   -- treated as one section in the logical structure of the input stream. What is done with the section depends on the
   -- combinator, but the sections, and therefore the logical structure of the input stream, are determined by the
   -- argument splitter alone.
   foreach, having, havingOnly, followedBy, even,
   -- ** first and its variants
   first, uptoFirst, prefix,
   -- ** last and its variants
   last, lastAndAfter, suffix,
   -- ** positional splitters
   startOf, endOf, between,
   -- * Parser support
   splitterToMarker, splittersToPairMarker, parserToSplitter, parseRegions,
   -- * Helper functions
   groupMarks, findsTrueIn, findsFalseIn, teeConsumers
   )
where
   
import Prelude hiding (drop, even, join, last, length, map, null, sequence)
import Control.Monad (liftM, void, when)
import Control.Monad.Trans.Class (lift)
import Data.Maybe (isJust, mapMaybe)
import Data.Monoid (Monoid, mempty, mconcat)
import qualified Data.Foldable as Foldable
import qualified Data.List as List (map)
import qualified Data.Sequence as Seq
import Data.Sequence (Seq, (<|), (|>), (><), ViewL (EmptyL, (:<)))

import Control.Monad.Coroutine
import Data.Monoid.Null (MonoidNull(null))
import Data.Monoid.Factorial (FactorialMonoid, length, drop)

import Control.Concurrent.SCC.Streams
import Control.Concurrent.SCC.Types
import Control.Concurrent.SCC.Coercions

-- | Converts a 'Consumer' into a 'Transducer' with no output.
consumeBy :: forall m x y r. (Monad m) => Consumer m x r -> Transducer m x y
consumeBy c = Transducer $ \ source _sink -> consume c source >> return ()

class CompatibleSignature c cons (m :: * -> *) input output | c -> cons m

instance CompatibleSignature (Performer m r)    (PerformerType r)  m x y
instance CompatibleSignature (Consumer m x r)   (ConsumerType r)   m x y
instance CompatibleSignature (Producer m x r)   (ProducerType r)   m y x
instance CompatibleSignature (Transducer m x y)  TransducerType    m x y

data PerformerType r
data ConsumerType r
data ProducerType r
data TransducerType

-- | Class 'JoinableComponentPair' applies to any two components that can be combined into a third component with the
-- following properties:
--
--    * if both argument components consume input, the input of the combined component gets distributed to both
--      components in parallel, and
--
--    * if both argument components produce output, the output of the combined component is a concatenation of the
--      complete output from the first component followed by the complete output of the second component.
class (Monad m, CompatibleSignature c1 t1 m x y, CompatibleSignature c2 t2 m x y, CompatibleSignature c3 t3 m x y)
   => JoinableComponentPair t1 t2 t3 m x y c1 c2 c3 | c1 c2 -> c3, c1 -> t1 m, c2 -> t2 m, c3 -> t3 m x y,
                                                      t1 m x y -> c1, t2 m x y -> c2, t3 m x y -> c3
   where 
      -- | The 'join' combinator may apply the components in any order.
      join :: PairBinder m -> c1 -> c2 -> c3
      join = const sequence
      -- | The 'sequence' combinator makes sure its first argument has completed before using the second one.
      sequence :: c1 -> c2 -> c3

instance forall m x r1 r2. Monad m =>
   JoinableComponentPair (ProducerType r1) (ProducerType r2) (ProducerType r2) m () x
                         (Producer m x r1) (Producer m x r2) (Producer m x r2)
   where sequence p1 p2 = Producer $ \sink-> produce p1 sink >> produce p2 sink

instance forall m x. Monad m =>
   JoinableComponentPair (ConsumerType ()) (ConsumerType ()) (ConsumerType ()) m x ()
                         (Consumer m x ()) (Consumer m x ()) (Consumer m x ())
   where join binder c1 c2 = Consumer (liftM (const ()) . teeConsumers binder (consume c1) (consume c2))
         sequence c1 c2 = Consumer $ \source->
                          teeConsumers sequentialBinder (consume c1) getAll source
                          >>= \((), list)-> pipe (flip putChunk list) (consume c2)
                          >> return ()

instance forall m x y. (Monad m, Monoid x, Monoid y) =>
   JoinableComponentPair TransducerType TransducerType TransducerType m x y
                         (Transducer m x y) (Transducer m x y) (Transducer m x y)
   where join binder t1 t2 = isolateTransducer $ \source sink->
                             pipe
                                (\buffer-> teeConsumers binder
                                              (\source'-> transduce t1 source' sink)
                                              (\source'-> transduce t2 source' buffer)
                                              source)
                                getAll
                             >>= \(_, list)-> putChunk sink list
                             >> return ()
         sequence t1 t2 = isolateTransducer $ \source sink->
                          teeConsumers sequentialBinder (flip (transduce t1) sink) getAll source
                          >>= \(_, list)-> pipe (flip putChunk list) (\source'-> transduce t2 source' sink)
                          >> return ()

instance forall m r1 r2. Monad m =>
   JoinableComponentPair (PerformerType r1) (PerformerType r2) (PerformerType r2) m () ()
                         (Performer m r1) (Performer m r2) (Performer m r2)
   where join binder p1 p2 = Performer $ binder (const return) (perform p1) (perform p2)
         sequence p1 p2 = Performer $ perform p1 >> perform p2

instance forall m x r1 r2. Monad m =>
   JoinableComponentPair (PerformerType r1) (ProducerType r2) (ProducerType r2) m () x
                         (Performer m r1) (Producer m x r2) (Producer m x r2)
   where join binder pe pr = Producer $ \sink-> liftBinder binder (const return) (lift (perform pe)) (produce pr sink)
         sequence pe pr = Producer $ \sink-> lift (perform pe) >> produce pr sink

instance forall m x r1 r2. Monad m =>
   JoinableComponentPair (ProducerType r1) (PerformerType r2) (ProducerType r2) m () x
                         (Producer m x r1) (Performer m r2) (Producer m x r2)
   where join binder pr pe = Producer $ \sink-> liftBinder binder (const return) (produce pr sink) (lift (perform pe))
         sequence pr pe = Producer $ \sink-> produce pr sink >> lift (perform pe)

instance forall m x r1 r2. Monad m =>
   JoinableComponentPair (PerformerType r1) (ConsumerType r2) (ConsumerType r2) m x ()
                         (Performer m r1) (Consumer m x r2) (Consumer m x r2)
   where join binder p c = Consumer $ \source-> liftBinder binder (const return) (lift (perform p)) (consume c source)
         sequence p c = Consumer $ \source-> lift (perform p) >> consume c source

instance forall m x r1 r2. Monad m =>
   JoinableComponentPair (ConsumerType r1) (PerformerType r2) (ConsumerType r2) m x ()
                         (Consumer m x r1) (Performer m r2) (Consumer m x r2)
   where join binder c p = Consumer $ \source-> liftBinder binder (const return) (consume c source) (lift (perform p))
         sequence c p = Consumer $ \source-> consume c source >> lift (perform p)

instance forall m x y r. Monad m =>
   JoinableComponentPair (PerformerType r) TransducerType TransducerType m x y
                         (Performer m r) (Transducer m x y) (Transducer m x y)
   where join binder p t = 
            Transducer $ \ source sink -> 
            liftBinder binder (const return) (lift (perform p)) (transduce t source sink)
         sequence p t = Transducer $ \ source sink -> lift (perform p) >> transduce t source sink

instance forall m x y r. Monad m
   => JoinableComponentPair TransducerType (PerformerType r) TransducerType m x y
                            (Transducer m x y) (Performer m r) (Transducer m x y)
   where join binder t p = 
            Transducer $ \ source sink -> 
            liftBinder binder (const . return) (transduce t source sink) (lift (perform p))
         sequence t p = Transducer $ \ source sink -> do result <- transduce t source sink
                                                         _ <- lift (perform p)
                                                         return result

instance forall m x y. (Monad m, Monoid x, Monoid y) =>
   JoinableComponentPair (ProducerType ()) TransducerType TransducerType m x y
                         (Producer m y ()) (Transducer m x y) (Transducer m x y)
   where join binder p t = 
            isolateTransducer $ \source sink->
            pipe (\buffer-> liftBinder binder (const return) (produce p sink) (transduce t source buffer)) getAll
            >>= \(_, out)-> putChunk sink out >> return ()
         sequence p t = Transducer $ \ source sink -> produce p sink >> transduce t source sink

instance forall m x y. (Monad m, Monoid x, Monoid y) =>
   JoinableComponentPair TransducerType (ProducerType ()) TransducerType m x y
                         (Transducer m x y) (Producer m y ()) (Transducer m x y)
   where join binder t p =
            isolateTransducer $ \source sink->
            pipe (\buffer-> liftBinder binder (const . return) (transduce t source sink) (produce p buffer)) getAll
            >>= \(_, out)-> putChunk sink out >> return ()
         sequence t p = Transducer $ \ source sink -> do result <- transduce t source sink
                                                         produce p sink
                                                         return result

instance forall m x y. (Monad m, Monoid x, Monoid y) =>
   JoinableComponentPair (ConsumerType ()) TransducerType TransducerType m x y
                         (Consumer m x ()) (Transducer m x y) (Transducer m x y)
   where join binder c t = 
            isolateTransducer $ \source sink->
            teeConsumers binder (consume c) (\source'-> transduce t source' sink) source
            >> return ()
         sequence c t = isolateTransducer $ \source sink->
                        teeConsumers sequentialBinder (consume c) getAll source
                        >>= \(_, list)-> pipe (flip putChunk list) (\source'-> transduce t source' sink)
                        >> return ()

instance forall m x y. (Monad m, Monoid x, Monoid y) =>
   JoinableComponentPair TransducerType (ConsumerType ()) TransducerType m x y
                         (Transducer m x y) (Consumer m x ()) (Transducer m x y)
   where join binder t c = join binder c t
         sequence t c = isolateTransducer $ \source sink->
                        teeConsumers sequentialBinder (\source'-> transduce t source' sink) getAll source
                        >>= \(_, list)-> pipe (flip putChunk list) (consume c)
                        >> return ()

instance forall m x y. Monad m =>
   JoinableComponentPair (ProducerType ()) (ConsumerType ()) TransducerType m x y
                         (Producer m y ()) (Consumer m x ()) (Transducer m x y)
   where join binder p c = Transducer $ 
                           \ source sink -> liftBinder binder (\ _ _ -> return ()) (produce p sink) (consume c source)
         sequence p c = Transducer $ \ source sink -> produce p sink >> consume c source

instance forall m x y. Monad m =>
   JoinableComponentPair (ConsumerType ()) (ProducerType ()) TransducerType m x y
                         (Consumer m x ()) (Producer m y ()) (Transducer m x y)
   where join binder c p = join binder p c
         sequence c p = Transducer $ \ source sink -> consume c source >> produce p sink

-- | Combinator 'prepend' converts the given producer to a 'Control.Concurrent.SCC.Types.Transducer' that passes all its
-- input through unmodified, except for prepending the output of the argument producer to it. The following law holds: @
-- 'prepend' /prefix/ = 'join' ('substitute' /prefix/) 'Control.Category.id' @
prepend :: forall m x r. Monad m => Producer m x r -> Transducer m x x
prepend prefixProducer = Transducer $ \ source sink -> produce prefixProducer sink >> pour_ source sink

-- | Combinator 'append' converts the given producer to a 'Control.Concurrent.SCC.Types.Transducer' that passes all its
-- input through unmodified, finally appending the output of the argument producer to it. The following law holds: @
-- 'append' /suffix/ = 'join' 'Control.Category.id' ('substitute' /suffix/) @
append :: forall m x r. Monad m => Producer m x r -> Transducer m x x
append suffixProducer = Transducer $ \ source sink -> pour source sink >> produce suffixProducer sink >> return ()

-- | The 'substitute' combinator converts its argument producer to a 'Control.Concurrent.SCC.Types.Transducer' that
-- produces the same output, while consuming its entire input and ignoring it.
substitute :: forall m x y r. (Monad m, Monoid x) => Producer m y r -> Transducer m x y
substitute feed = Transducer $ 
                  \ source sink -> mapMStreamChunks_ (const $ return ()) source >> produce feed sink >> return ()

-- | The 'sNot' (streaming not) combinator simply reverses the outputs of the argument splitter. In other words, data
-- that the argument splitter sends to its /true/ sink goes to the /false/ sink of the result, and vice versa.
sNot :: forall m x. (Monad m, Monoid x) => Splitter m x -> Splitter m x
sNot splitter = isolateSplitter s
   where s :: forall d. Functor d => Source m d x -> Sink m d x -> Sink m d x -> Coroutine d m ()
         s source true false = split splitter source false true

-- | The 'sAnd' combinator sends the /true/ sink output of its left operand to the input of its right operand for
-- further splitting. Both operands' /false/ sinks are connected to the /false/ sink of the combined splitter, but any
-- input value to reach the /true/ sink of the combined component data must be deemed true by both splitters.
sAnd :: forall m x. (Monad m, Monoid x) => PairBinder m -> Splitter m x -> Splitter m x -> Splitter m x
sAnd binder s1 s2 =
   isolateSplitter $ \ source true false ->
   liftM fst $
   pipeG binder
      (\true'-> split s1 source true' false)
      (\source'-> split s2 source' true false)

-- | A 'sOr' combinator's input value can reach its /false/ sink only by going through both argument splitters' /false/
-- sinks.
sOr :: forall m x. (Monad m, Monoid x) => PairBinder m -> Splitter m x -> Splitter m x -> Splitter m x
sOr binder s1 s2 = 
   isolateSplitter $ \ source true false ->
   liftM fst $
   pipeG binder
      (\false'-> split s1 source true false')
      (\source'-> split s2 source' true false)

-- | Combinator 'pAnd' is a pairwise logical conjunction of two splitters run in parallel on the same input.
pAnd :: forall m x. (Monad m, FactorialMonoid x) => PairBinder m -> Splitter m x -> Splitter m x -> Splitter m x
pAnd = zipSplittersWith (&&)

-- | Combinator 'pOr' is a pairwise logical disjunction of two splitters run in parallel on the same input.
pOr :: forall m x. (Monad m, FactorialMonoid x) => PairBinder m -> Splitter m x -> Splitter m x -> Splitter m x
pOr = zipSplittersWith (||)

ifs :: forall c m x. (Monad m, Branching c m x ()) => PairBinder m -> Splitter m x -> c -> c -> c
ifs binder s c1 c2 = combineBranches if' binder c1 c2
   where if' :: forall d. PairBinder m -> (forall a d'. AncestorFunctor d d' => OpenConsumer m a d' x ()) ->
                (forall a d'. AncestorFunctor d d' => OpenConsumer m a d' x ()) ->
                forall a. OpenConsumer m a d x ()
         if' binder' c1' c2' source = splitInputToConsumers binder' s source c1' c2'

wherever :: forall m x. (Monad m, Monoid x) => PairBinder m -> Transducer m x x -> Splitter m x -> Transducer m x x
wherever binder t s = isolateTransducer wherever'
   where wherever' :: forall d. Functor d => Source m d x -> Sink m d x -> Coroutine d m ()
         wherever' source sink = pipeG binder
                                    (\true-> split s source true sink)
                                    (flip (transduce t) sink)
                                 >> return ()

unless :: forall m x. (Monad m, Monoid x) => PairBinder m -> Transducer m x x -> Splitter m x -> Transducer m x x
unless binder t s = wherever binder t (sNot s)

select :: forall m x. (Monad m, Monoid x) => Splitter m x -> Transducer m x x
select s = isolateTransducer t 
   where t :: forall d. Functor d => Source m d x -> Sink m d x -> Coroutine d m ()
         t source sink = split s source sink (nullSink :: Sink m d x)

-- | Converts a splitter into a parser.
parseRegions :: forall m x. (Monad m, MonoidNull x) => Splitter m x -> Parser m x ()
parseRegions s = isolateTransducer $ \source sink->
                    pipe
                       (transduce (splitterToMarker s) source)
                       (\source'-> concatMapAccumStream wrap Nothing source' sink 
                                   >>= maybe (return ()) (put sink . flush))
                    >> return ()
   where wrap Nothing (x, False) = (Nothing, if null x then [] else [Content x])
         wrap Nothing (x, True) | null x = (Just ((), False), [])
                                | otherwise = (Just ((), True), [Markup (Start ()), Content x])
         wrap (Just p) (x, False) = (Nothing, if null x then [flush p] else [flush p, Content x])
         wrap (Just (b, t)) (x, True) = (Just (b, True), if t then [Content x] else [Markup (Start b), Content x])
         flush (b, t) = Markup $ (if t then End else Point) b

-- | The recursive combinator 'while' feeds the true sink of the argument splitter back to itself, modified by the
-- argument transducer. Data fed to the splitter's false sink is passed on unmodified.
while :: forall m x. (Monad m, MonoidNull x) => 
         PairBinder m -> Transducer m x x -> Splitter m x -> Transducer m x x -> Transducer m x x
while binder t s whileRest = isolateTransducer while'
   where while' :: forall d. Functor d => Source m d x -> Sink m d x -> Coroutine d m ()
         while' source sink =
            pipeG binder
               (\true'-> split s source true' sink)
               (\source'-> getRead readEof source'
                           >>= flip (when . not) (transduce (compose binder t whileRest) source' sink))
            >> return ()

-- | The recursive combinator 'nestedIn' combines two splitters into a mutually recursive loop acting as a single
-- splitter. The true sink of one of the argument splitters and false sink of the other become the true and false sinks
-- of the loop. The other two sinks are bound to the other splitter's source. The use of 'nestedIn' makes sense only on
-- hierarchically structured streams. If we gave it some input containing a flat sequence of values, and assuming both
-- component splitters are deterministic and stateless, an input value would either not loop at all or it would loop
-- forever.
nestedIn :: forall m x. (Monad m, MonoidNull x) => 
            PairBinder m -> Splitter m x -> Splitter m x -> Splitter m x -> Splitter m x
nestedIn binder s1 s2 nestedRest =
   isolateSplitter $ \ source true false ->
   liftM fst $
      pipeG binder
         (\false'-> split s1 source true false')
         (\source'-> pipe
                        (\true'-> splitInput s2 source' true' false)
                        (\source''-> getRead readEof source''
                                     >>= flip (when . not) (split nestedRest source'' true false)))

-- | The 'foreach' combinator is similar to the combinator 'ifs' in that it combines a splitter and two transducers into
-- another transducer. However, in this case the transducers are re-instantiated for each consecutive portion of the
-- input as the splitter chunks it up. Each contiguous portion of the input that the splitter sends to one of its two
-- sinks gets transducered through the appropriate argument transducer as that transducer's whole input. As soon as the
-- contiguous portion is finished, the transducer gets terminated.
foreach :: forall m x c. (Monad m, MonoidNull x, Branching c m x ()) => PairBinder m -> Splitter m x -> c -> c -> c
foreach binder s c1 c2 = combineBranches foreach' binder c1 c2
   where foreach' :: forall d. PairBinder m -> 
                     (forall a d'. AncestorFunctor d d' => OpenConsumer m a d' x ()) ->
                     (forall a d'. AncestorFunctor d d' => OpenConsumer m a d' x ()) ->
                     forall a. OpenConsumer m a d x ()
         foreach' binder' c1' c2' source =
            liftM fst $
            pipeG binder'
               (transduce (splitterToMarker s) (liftSource source :: Source m d x))
               (\source'-> groupMarks source' (\b-> if b then c1' else c2'))

-- | The 'having' combinator combines two pure splitters into a pure splitter. One splitter is used to chunk the input
-- into contiguous portions. Its /false/ sink is routed directly to the /false/ sink of the combined splitter. The
-- second splitter is instantiated and run on each portion of the input that goes to first splitter's /true/ sink. If
-- the second splitter sends any output at all to its /true/ sink, the whole input portion is passed on to the /true/
-- sink of the combined splitter, otherwise it goes to its /false/ sink.
having :: forall m x y. (Monad m, MonoidNull x, MonoidNull y, Coercible x y) =>
          PairBinder m -> Splitter m x -> Splitter m y -> Splitter m x
having binder s1 s2 = isolateSplitter s
   where s :: forall d. Functor d => Source m d x -> Sink m d x -> Sink m d x -> Coroutine d m ()
         s source true false = pipeG binder
                                  (transduce (splitterToMarker s1) source)
                                  (flip groupMarks test)
                               >> return ()
            where test False chunk = pour_ chunk false
                  test True chunk =
                     do chunkBuffer <- getAll chunk
                        (_, found) <- pipe (produce $ adaptProducer $ Producer $ putAll chunkBuffer) (findsTrueIn s2)
                        if found
                           then putChunk true chunkBuffer
                           else putAll chunkBuffer false
                        return ()

-- | The 'havingOnly' combinator is analogous to the 'having' combinator, but it succeeds and passes each chunk of the
-- input to its /true/ sink only if the second splitter sends no part of it to its /false/ sink.
havingOnly :: forall m x y. (Monad m, MonoidNull x, MonoidNull y, Coercible x y) =>
              PairBinder m -> Splitter m x -> Splitter m y -> Splitter m x
havingOnly binder s1 s2 = isolateSplitter s
   where s :: forall d. Functor d => Source m d x -> Sink m d x -> Sink m d x -> Coroutine d m ()
         s source true false = pipeG binder
                                  (transduce (splitterToMarker s1) source)
                                  (flip groupMarks test)
                               >> return ()
            where test False chunk = pour_ chunk false
                  test True chunk =
                     do chunkBuffer <- getAll chunk
                        (_, anyFalse) <-
                           pipe (produce $ adaptProducer $ Producer $ putAll chunkBuffer) (findsFalseIn s2)
                        if anyFalse
                           then putAll chunkBuffer false
                           else putChunk true chunkBuffer
                        return ()

-- | The result of combinator 'first' behaves the same as the argument splitter up to and including the first portion of
-- the input which goes into the argument's /true/ sink. All input following the first true portion goes into the
-- /false/ sink.
first :: forall m x. (Monad m, MonoidNull x) => Splitter m x -> Splitter m x
first splitter = wrapMarkedSplitter splitter $
                 \source true false->
                    pourUntil (snd . head) source (markDown false)
                    >>= Foldable.mapM_
                           (\_-> pourWhile (snd . head) source (markDown true)
                                 >> concatMapStream fst source false)

-- | The result of combinator 'uptoFirst' takes all input up to and including the first portion of the input which goes
-- into the argument's /true/ sink and feeds it to the result splitter's /true/ sink. All the rest of the input goes
-- into the /false/ sink. The only difference between 'first' and 'uptoFirst' combinators is in where they direct the
-- /false/ portion of the input preceding the first /true/ part.
uptoFirst :: forall m x. (Monad m, MonoidNull x) => Splitter m x -> Splitter m x
uptoFirst splitter = wrapMarkedSplitter splitter $
                     \source true false->
                     do (pfx, mx) <- getUntil (snd . head) source
                        let prefix' = mconcat $ List.map (\(x, False)-> x) pfx
                        maybe
                           (putAll prefix' false >> return ())
                           (\[x]-> putAll prefix' true
                                   >> pourWhile (snd . head) source (markDown true)
                                   >> concatMapStream fst source false)
                           mx

-- | The result of the combinator 'last' is a splitter which directs all input to its /false/ sink, up to the last
-- portion of the input which goes to its argument's /true/ sink. That portion of the input is the only one that goes to
-- the resulting component's /true/ sink.  The splitter returned by the combinator 'last' has to buffer the previous two
-- portions of its input, because it cannot know if a true portion of the input is the last one until it sees the end of
-- the input or another portion succeeding the previous one.
last :: forall m x. (Monad m, MonoidNull x) => Splitter m x -> Splitter m x
last splitter = 
   wrapMarkedSplitter splitter $ 
   \source true false->
   let split1 = getUntil (not . snd . head) source >>= split2
       split2 (trues, Nothing) = putChunk true (mconcat $ List.map fst trues)
       split2 (trues, Just [~(_, False)]) = getUntil (snd . head) source >>= split3 trues
       split3 ts (fs, Nothing) = putChunk true (mconcat $ List.map fst ts) >> putAll (mconcat $ List.map fst fs) false
       split3 ts (fs, x@Just{}) = putAll (mconcat $ List.map fst ts) false >> putAll (mconcat $ List.map fst fs) false 
                                  >> split1
   in pourUntil (snd . head) source (markDown false) 
      >>= Foldable.mapM_ (const split1)

-- | The result of the combinator 'lastAndAfter' is a splitter which directs all input to its /false/ sink, up to the
-- last portion of the input which goes to its argument's /true/ sink. That portion and the remainder of the input is
-- fed to the resulting component's /true/ sink. The difference between 'last' and 'lastAndAfter' combinators is where
-- they feed the /false/ portion of the input, if any, remaining after the last /true/ part.
lastAndAfter :: forall m x. (Monad m, MonoidNull x) => Splitter m x -> Splitter m x
lastAndAfter splitter = 
   wrapMarkedSplitter splitter $
   \source true false->
   let split1 = getUntil (not . snd . head) source >>= split2
       split2 (trues, Nothing) = putChunk true (mconcat $ List.map fst trues)
       split2 (trues, Just [~(_, False)]) = getUntil (snd . head) source >>= split3 trues
       split3 ts (fs, Nothing) = putChunk true (mconcat $ List.map fst ts) >> putChunk true (mconcat $ List.map fst fs)
       split3 ts (fs, x@Just{}) = putAll (mconcat $ List.map fst ts) false >> putAll (mconcat $ List.map fst fs) false 
                                  >> split1
   in pourUntil (snd . head) source (markDown false) 
      >>= Foldable.mapM_ (const split1)

-- | The 'prefix' combinator feeds its /true/ sink only the prefix of the input that its argument feeds to its /true/
-- sink.  All the rest of the input is dumped into the /false/ sink of the result.
prefix :: forall m x. (Monad m, MonoidNull x) => Splitter m x -> Splitter m x
prefix splitter = wrapMarkedSplitter splitter splitMarked
   where splitMarked :: forall a1 a2 a3 d. (AncestorFunctor a1 d, AncestorFunctor a2 d, AncestorFunctor a3 d,
                                            AncestorFunctor a1 (SinkFunctor d [(x, Bool)]),
                                            AncestorFunctor a2 (SourceFunctor d [(x, Bool)])) =>
                        Source m a1 [(x, Bool)] -> Sink m a2 x -> Sink m a3 x -> Coroutine d m ()
         splitMarked source true false =
            pourUntil (not . null . fst . head) source (nullSink :: Sink m d [(x, Bool)])
            >>= maybe
                   (return ())
                   (\[x0]-> when (snd x0) (pourWhile (snd . head) source (markDown true))
                            >> concatMapStream fst source false)

-- | The 'suffix' combinator feeds its /true/ sink only the suffix of the input that its argument feeds to its /true/
-- sink.  All the rest of the input is dumped into the /false/ sink of the result.
suffix :: forall m x. (Monad m, MonoidNull x) => Splitter m x -> Splitter m x
suffix splitter = 
   wrapMarkedSplitter splitter $
   \source true false->
   let split0 = pourUntil (snd . head) source (markDown false)
                >>= Foldable.mapM_ (const split1)
       split1 = getUntil (not . snd . head) source >>= split2
       split2 (trues, Nothing) = putAll (mconcat $ List.map fst trues) true >> return ()
       split2 (trues, Just [(x, False)]) 
          | null x = do (_, mr) <- getUntil (not . null . fst . head) source
                        case mr of Nothing -> putAll (mconcat $ List.map fst trues) true 
                                              >> return ()
                                   Just{} -> putAll (mconcat $ List.map fst trues) false 
                                             >> split0
          | otherwise = putAll (mconcat $ List.map fst trues) false  >> split0
   in split0

-- | The 'even' combinator takes every input section that its argument /splitter/ deems /true/, and feeds even ones into
-- its /true/ sink. The odd sections and parts of input that are /false/ according to its argument splitter are fed to
-- 'even' splitter's /false/ sink.
even :: forall m x. (Monad m, MonoidNull x) => Splitter m x -> Splitter m x
even splitter = wrapMarkedSplitter splitter $
                \source true false->
                let false' = markDown false
                    split0 = pourUntil (snd . head) source false' >>= split1
                    split1 Nothing = return ()
                    split1 (Just [~(_, True)]) = split2
                    split2 = pourUntil (not . snd . head) source false' >>= split3
                    split3 Nothing = return ()
                    split3 (Just [~(_, False)]) = pourUntil (snd . head) source false' >>= split4
                    split4 Nothing = return ()
                    split4 (Just [~(_, True)]) = split5
                    split5 = pourWhile (snd . head) source (markDown true) >> split0
                in split0

-- | Splitter 'startOf' issues an empty /true/ section at the beginning of every section considered /true/ by its
-- argument splitter, otherwise the entire input goes into its /false/ sink.
startOf :: forall m x. (Monad m, MonoidNull x) => Splitter m x -> Splitter m x
startOf splitter = wrapMarkedSplitter splitter $
                   \source true false->
                   let false' = markDown false
                       split0 = pourUntil (snd . head) source false' >>= split1
                       split1 Nothing = return ()
                       split1 (Just [~(_, True)]) = putChunk true mempty >> split2
                       split2 = pourUntil (not . snd . head) source false' >>= split3
                       split3 Nothing = return ()
                       split3 (Just [~(_, False)]) = split0
                   in split0

-- | Splitter 'endOf' issues an empty /true/ section at the end of every section considered /true/ by its argument
-- splitter, otherwise the entire input goes into its /false/ sink.
endOf :: forall m x. (Monad m, MonoidNull x) => Splitter m x -> Splitter m x
endOf splitter = wrapMarkedSplitter splitter $
                 \source true false->
                 let false' = markDown false
                     split0 = pourUntil (snd . head) source false' >>= split1
                     split1 Nothing = return ()
                     split1 (Just [~(_, True)]) = split2
                     split2 = pourUntil (not . snd . head) source false'
                              >>= (putChunk true mempty >>) . split3
                     split3 Nothing = return ()
                     split3 (Just [~(_, False)]) = split0
                 in split0

-- | Combinator 'followedBy' treats its argument 'Splitter's as patterns components and returns a 'Splitter' that
-- matches their concatenation. A section of input is considered /true/ by the result iff its prefix is considered
-- /true/ by argument /s1/ and the rest of the section is considered /true/ by /s2/. The splitter /s2/ is started anew
-- after every section split to /true/ sink by /s1/.
followedBy :: forall m x. (Monad m, FactorialMonoid x) => PairBinder m -> Splitter m x -> Splitter m x -> Splitter m x
followedBy binder s1 s2 =
   isolateSplitter $ \ source true false ->
   pipeG binder
      (transduce (splitterToMarker s1) source)
      (\source'->
       let false' = markDown false
           get0 q = case Seq.viewl q
                    of Seq.EmptyL -> split0
                       (x, False) :< rest -> putChunk false x >> get0 rest
                       (_, True) :< _ -> get2 Seq.empty q
           split0 = pourUntil (snd . head) source' false'
                    >>= maybe
                           (return ())
                           (const $ split1) 
           split1 = do (list, mx) <- getUntil (not . snd . head) source'
                       let list' = Seq.fromList $ List.map (\(x, True)-> x) list
                       maybe
                          (testEnd (Seq.fromList $ List.map (\(x, True)-> x) list))
                          ((getPrime source' >>) . get3 list' . Seq.singleton . head)
                          mx
           get2 q q' = case Seq.viewl q'
                       of Seq.EmptyL -> get source'
                                        >>= maybe (testEnd q) (get2 q . Seq.singleton)
                          (x, True) :< rest -> get2 (q |> x) rest
                          (_, False) :< _ -> get3 q q'
           get3 q q' = do let list = mconcat $ List.map fst (Foldable.toList $ Seq.viewl q')
                          (q'', mn) <- pipe (\sink-> putAll list sink >> get7 q' sink) (test q)
                          case mn of Nothing -> putQueue q false >> get0 q''
                                     Just 0 -> get0 q''
                                     Just n -> get8 True n q''
           get7 q sink = do list <- getWhile (const True . head) source'
                            rest <- putAll (mconcat $ List.map (\(x, _)-> x) list) sink
                            let q' = q >< Seq.fromList list
                            if null rest
                               then get source' >>= maybe (return q') (\x-> get7 (q' |> x) sink)
                               else return q'
           testEnd q = do ((), n) <- pipe (const $ return ()) (test q)
                          case n of Nothing -> putQueue q false >> return ()
                                    _ -> return ()
           test q source'' = liftM snd $
                             pipe
                                (transduce (splitterToMarker s2) source'')
                                (\source'''-> 
                                  let test0 (x, False) = getPrime source'''
                                                         >> if null x then try0 else return Nothing
                                      test0 (_, True) = test1
                                      test1 = do putQueue q true
                                                 list <- getWhile (snd . head) source'''
                                                 let chunk = mconcat (List.map fst list)
                                                 putChunk true chunk
                                                 getPrime source'''
                                                 return (Just $ length chunk)
                                      try0 = peek source''' >>= maybe (return Nothing) test0
                                  in try0)
           get8 False 0 q = get0 q
           get8 True 0 q = get2 Seq.empty q
           get8 _ n q | n > 0 =
              case Seq.viewl q
              of (x, False) :< rest | length x > n -> get0 ((drop n x, False) <| rest)
                                    | otherwise -> get8 False (n - length x) rest
                 (x, True) :< rest | length x > n -> get2 Seq.empty ((drop n x, True) <| rest)
                                   | otherwise -> get8 True (n - length x) rest
                 EmptyL -> error "Expecting a non-empty queue!"
       in split0)
      >> return ()

-- | Combinator 'between' tracks the running balance of difference between the number of preceding starts of sections
-- considered /true/ according to its first argument and the ones according to its second argument. The combinator
-- passes to /true/ all input values for which the difference balance is positive. This combinator is typically used
-- with 'startOf' and 'endOf' in order to count entire input sections and ignore their lengths.
between :: forall m x. (Monad m, FactorialMonoid x) => PairBinder m -> Splitter m x -> Splitter m x -> Splitter m x
between binder s1 s2 = isolateSplitter $
                       \ source true false ->
                       pipeG binder
                          (transduce (splittersToPairMarker binder s1 s2) source)
                          (let pass n x = (if n > 0 then putChunk true x else putChunk false x)
                                          >> return n
                               pass' n x = (if n >= 0 then putChunk true x else putChunk false x)
                                           >> return n
                               state n (x, True, False) = pass (succ n) x
                               state n (x, False, True) = pass' (pred n) x
                               state n (x, True, True) = pass' n x
                               state n (x, False, False) = pass n x
                           in foldMStream_ state (0 :: Int))
                          >> return ()

-- Helper functions

wrapMarkedSplitter ::
   forall m x. (Monad m, MonoidNull x) =>
   Splitter m x
   -> (forall a1 a2 a3 d. (AncestorFunctor a1 d, AncestorFunctor a2 d, AncestorFunctor a3 d,
                           AncestorFunctor a1 (SinkFunctor d [(x, Bool)]),
                           AncestorFunctor a2 (SourceFunctor d [(x, Bool)])) =>
       Source m a1 [(x, Bool)] -> Sink m a2 x -> Sink m a3 x -> Coroutine d m ())
   -> Splitter m x
wrapMarkedSplitter splitter splitMarked = isolateSplitter $ 
                                          \ source true false ->
                                          pipe
                                             (transduce (splitterToMarker splitter) source)
                                             (\source'-> splitMarked source' true false)
                                          >> return ()

splitterToMarker :: forall m x. (Monad m, MonoidNull x) => Splitter m x -> Transducer m x [(x, Bool)]
splitterToMarker s = isolateTransducer mark
   where mark :: forall d. Functor d => Source m d x -> Sink m d [(x, Bool)] -> Coroutine d m ()
         mark source sink = split s source (markUpWith True sink) (markUpWith False sink)

parserToSplitter :: forall m x b. (Monad m, Monoid x) => Parser m x b -> Splitter m x
parserToSplitter t = isolateSplitter $ \ source true false ->
                     pipe
                        (transduce t source)
                        (\source-> 
                          pipe (\true'->
                                 pipe (\false'->
                                        let topLevel = pourWhile isContent source false'
                                                       >> get source 
                                                       >>= maybe (return ()) (\x-> handleMarkup x >> topLevel)
                                            handleMarkup (Markup p@Point{}) = putChunk true mempty >> return True
                                            handleMarkup (Markup s@Start{}) = putChunk true mempty >> handleRegion >> return True
                                            handleMarkup (Markup e@End{}) = putChunk false mempty >> return False
                                            handleRegion = pourWhile isContent source true'
                                                           >> get source
                                                           >>= maybe (return ()) (\x -> handleMarkup x 
                                                                                        >>= flip when handleRegion)
                                        in topLevel)
                                      (\src-> concatMapStream (\(Content x)-> x) src false))
                               (\src-> concatMapStream (\(Content x)-> x) src true))
                                                           
                        >> return ()
   where isContent [Markup{}] = False
         isContent [Content{}] = True
         fromContent (Content x) = x

splittersToPairMarker :: forall m x. (Monad m, FactorialMonoid x) => PairBinder m -> Splitter m x -> Splitter m x ->
                         Transducer m x [(x, Bool, Bool)]
splittersToPairMarker binder s1 s2 =
   let synchronizeMarks :: forall a1 a2 d. (AncestorFunctor a1 d, AncestorFunctor a2 d) =>
                           Sink m a1 [(x, Bool, Bool)]
                        -> Source m a2 [((x, Bool), Bool)]
                        -> Coroutine d m (Maybe (Seq (x, Bool), Bool))
       synchronizeMarks sink source = foldMStream handleMark Nothing source where
          handleMark Nothing (p@(x, _), b) = return (Just (Seq.singleton p, b))
          handleMark (Just (q, b)) mark@(p@(x, t), b')
             | b == b' = return (Just (q |> p, b))
             | otherwise = case Seq.viewl q
                           of Seq.EmptyL -> handleMark Nothing mark
                              (y, t') :< rest -> put sink (if b then (common, t', t) else (common, t, t'))
                                                 >> if lx == ly
                                                    then return (if Seq.null rest then Nothing else Just (rest, b))
                                                    else if lx < ly 
                                                         then return (Just ((leftover, t') <| rest, b))
                                                         else handleMark (if Seq.null rest then Nothing 
                                                                          else Just (rest, b)) 
                                                                         ((leftover, t), b')
                                 where lx = length x
                                       ly = length y
                                       (common, leftover) = if lx < ly then (x, drop lx y) else (y, drop ly x)
   in isolateTransducer $
      \source sink->
      pipe
         (\sync-> teeConsumers binder
                     (\source1-> transduce (splitterToMarker s1) source1 (mapSink (\x-> (x, True)) sync))
                     (\source2-> transduce (splitterToMarker s2) source2 (mapSink (\x-> (x, False)) sync))
                     source)
         (synchronizeMarks sink)
      >> return ()

zipSplittersWith :: forall m x. (Monad m, FactorialMonoid x) =>
                    (Bool -> Bool -> Bool) -> PairBinder m -> Splitter m x -> Splitter m x -> Splitter m x
zipSplittersWith f binder s1 s2
   = isolateSplitter $ \ source true false ->
     pipeG binder
        (transduce (splittersToPairMarker binder s1 s2) source)
        (mapMStream_ (\[(x, t1, t2)]-> if f t1 t2 then putChunk true x else putChunk false x))
     >> return ()

-- | Runs the second argument on every contiguous region of input source (typically produced by 'splitterToMarker')
-- whose all values either match @Left (_, True)@ or @Left (_, False)@.
groupMarks :: (Monad m, MonoidNull x, AncestorFunctor a d, AncestorFunctor a (SinkFunctor d x), 
               AncestorFunctor a (SinkFunctor (SinkFunctor d x) [(x, Bool)])) =>
              Source m a [(x, Bool)] ->
              (Bool -> Source m (SourceFunctor d x) x -> Coroutine (SourceFunctor d x) m r) ->
              Coroutine d m ()
groupMarks source getConsumer = peek source >>= loop
   where loop = maybe (return ()) ((>>= loop . fst) . startContent)
         startContent (_, False) = pipe (next False) (getConsumer False)
         startContent (_, True) = pipe (next True) (getConsumer True)
         next t sink = liftM (fmap head) $
                       pourUntil ((\(_, t')-> t /= t') . head) source (markDown sink)

splitInput :: forall m a1 a2 a3 d x. (Monad m, Monoid x, 
                                      AncestorFunctor a1 d, AncestorFunctor a2 d, AncestorFunctor a3 d) =>
              Splitter m x -> Source m a1 x -> Sink m a2 x -> Sink m a3 x -> Coroutine d m ()
splitInput splitter source true false = split splitter source true false

findsTrueIn :: forall m a d x. (Monad m, MonoidNull x, AncestorFunctor a d)
               => Splitter m x -> Source m a x -> Coroutine d m Bool
findsTrueIn splitter source = pipe
                                 (\testTrue-> split splitter (liftSource source :: Source m d x)
                                                 testTrue
                                                 (nullSink :: Sink m d x))
                                 (getRead readEof)
                              >>= \((), eof)-> return $ not eof

findsFalseIn :: forall m a d x. (Monad m, MonoidNull x, AncestorFunctor a d) =>
                Splitter m x -> Source m a x -> Coroutine d m Bool
findsFalseIn splitter source = pipe
                                  (\testFalse-> split splitter (liftSource source :: Source m d x)
                                                   (nullSink :: Sink m d x)
                                                   testFalse)
                                  (getRead readEof)
                               >>= \((), eof)-> return $ not eof

readEof :: forall x. MonoidNull x => Reader x (Bool -> Bool) Bool
readEof x | null x = Deferred readEof True
          | otherwise = Final x False

teeConsumers :: forall m a d x r1 r2. Monad m => 
                PairBinder m 
                -> (forall a'. OpenConsumer m a' (SourceFunctor (SinkFunctor d x) x) x r1)
                -> (forall a'. OpenConsumer m a' (SourceFunctor d x) x r2)
                -> OpenConsumer m a d x (r1, r2)
teeConsumers binder c1 c2 source = pipeG binder consume1 c2
   where consume1 sink = liftM snd $ pipe (tee source' sink) c1
         source' :: Source m d x
         source' = liftSource source

-- | Given a 'Splitter', a 'Source', and two consumer functions, 'splitInputToConsumers' runs the splitter on the source
-- and feeds the splitter's /true/ and /false/ outputs, respectively, to the two consumers.
splitInputToConsumers :: forall m a d d1 x. (Monad m, Monoid x, d1 ~ SinkFunctor d x, AncestorFunctor a d) =>
                         PairBinder m -> Splitter m x -> Source m a x ->
                         (Source m (SourceFunctor d1 x) x -> Coroutine (SourceFunctor d1 x) m ()) ->
                         (Source m (SourceFunctor d x) x -> Coroutine (SourceFunctor d x) m ()) ->
                         Coroutine d m ()
splitInputToConsumers binder s source trueConsumer falseConsumer
   = pipeG binder
        (\false-> pipeG binder
                     (\true-> split s source' true false)
                     trueConsumer)
        falseConsumer
     >> return ()
   where source' :: Source m d x
         source' = liftSource source

-- | Like 'putAll', except it puts the contents of the given 'Data.Sequence.Seq' into the sink.
putQueue :: forall m a d x. (Monad m, MonoidNull x, AncestorFunctor a d) => Seq x -> Sink m a x -> Coroutine d m x
putQueue q sink = putAll (mconcat $ Foldable.toList $ Seq.viewl q) sink
