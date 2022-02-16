{- 
    Copyright 2008-2013 Mario Blazevic

    This file is part of the Streaming Component Combinators (SCC) project.

    The SCC project is free software: you can redistribute it and/or modify it under the terms of the GNU General Public
    License as published by the Free Software Foundation, either version 3 of the License, or (at your option) any later
    version.

    SCC is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY; without even the implied warranty
    of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU General Public License for more details.

    You should have received a copy of the GNU General Public License along with SCC.  If not, see
    <http://www.gnu.org/licenses/>.
-}

{-# LANGUAGE RankNTypes, KindSignatures, EmptyDataDecls,
             MultiParamTypeClasses, FlexibleContexts, FlexibleInstances, FunctionalDependencies, TypeFamilies #-}
{-# OPTIONS_HADDOCK prune #-}

-- | This module exports the entire SCC library except for low-level modules "Control.Concurrent.SCC.Streams" and
-- "Control.Concurrent.SCC.Types". The exported combinators can be configured to run their components sequentially or in
-- parallel depending on the available resources.

module Control.Concurrent.SCC.Configurable 
       (
          module Control.Concurrent.SCC.Configurable,
          module Control.Concurrent.Configuration,
          XML.XMLToken(..), XML.expandXMLEntity
       )
where

import Prelude hiding (appendFile, even, id, join, last, sequence, (||), (&&))
import qualified Control.Category
import Data.Text (Text)
import Data.Monoid (Monoid, Sum)
import System.IO (Handle)

import Control.Monad.Coroutine
import Control.Monad.Parallel (MonadParallel(..))
import Data.Monoid.Null (MonoidNull)
import Data.Monoid.Factorial (FactorialMonoid)
import Data.Monoid.Cancellative (LeftCancellativeMonoid)

import Control.Concurrent.SCC.Streams
import Control.Concurrent.SCC.Types
import Control.Concurrent.SCC.Coercions (Coercible)
import qualified Control.Concurrent.SCC.Coercions as Coercion
import qualified Control.Concurrent.SCC.Combinators as Combinator
import qualified Control.Concurrent.SCC.Primitives as Primitive
import qualified Control.Concurrent.SCC.XML as XML
import Control.Concurrent.SCC.Primitives (OccurenceTag)
import Control.Concurrent.SCC.XML (XMLToken)
import Control.Concurrent.Configuration (Component, atomic)
import qualified Control.Concurrent.Configuration as Configuration

-- * Configurable component types

-- | A component that performs a computation with no inputs nor outputs is a 'PerformerComponent'.
type PerformerComponent m r = Component (Performer m r)

-- | A component that consumes values from a 'Source' is called 'ConsumerComponent'.
type ConsumerComponent m x r = Component (Consumer m x r)

-- | A component that produces values and puts them into a 'Sink' is called 'ProducerComponent'.
type ProducerComponent m x r = Component (Producer m x r)

-- | The 'TransducerComponent' type represents computations that transform a data stream.
type TransducerComponent m x y = Component (Transducer m x y)

type ParserComponent m x y = Component (Parser m x y)

-- | The 'SplitterComponent' type represents computations that distribute data acording to some criteria.  A splitter
-- should distribute only the original input data, and feed it into the sinks in the same order it has been read from
-- the source. If the two 'Sink c x' arguments of a splitter are the same, the splitter must act as an identity
-- transform.
type SplitterComponent m x = Component (Splitter m x)

-- | The constant cost of each I/O-performing component.
ioCost :: Int
ioCost = 5

-- * Coercible class

-- | A 'TransducerComponent' that converts a stream of one type to another.
coerce :: (Monad m, Coercible x y) => TransducerComponent m x y
coerce = atomic "coerce" 1 Coercion.coerce

-- | Adjusts the argument consumer to consume the stream of a data type coercible to the type it was meant to consume.
adaptConsumer :: (Monad m, Monoid x, Monoid y, Coercible x y) => ConsumerComponent m y r -> ConsumerComponent m x r
adaptConsumer = Configuration.lift 1 "adaptConsumer" Coercion.adaptConsumer

-- | Adjusts the argument producer to produce the stream of a data type coercible from the type it was meant to produce.
adaptProducer :: (Monad m, Monoid x, Monoid y, Coercible x y) => ProducerComponent m x r -> ProducerComponent m y r
adaptProducer = Configuration.lift 1 "adaptProducer" Coercion.adaptProducer

-- * Splitter isomorphism

-- | Adjusts the argument splitter to split the stream of a data type isomorphic to the type it was meant to split.
adaptSplitter :: (Monad m, Monoid x, Monoid y, Coercible x y, Coercible y x) => 
                 SplitterComponent m x -> SplitterComponent m y
adaptSplitter = Configuration.lift 1 "adaptSplitter" Coercion.adaptSplitter

-- * I/O components
-- ** I/O producers

-- | ProducerComponent 'fromStdIn' feeds the given sink from the standard input.
fromStdIn :: ProducerComponent IO Text ()
fromStdIn = atomic "fromStdIn" ioCost Primitive.fromStdIn

-- | ProducerComponent 'fromFile' opens the named file and feeds the given sink from its contents.
fromFile :: String -> ProducerComponent IO Text ()
fromFile path = atomic "fromFile" ioCost (Primitive.fromFile path)

-- | ProducerComponent 'fromHandle' feeds the given sink from the open file /handle/.
fromHandle :: Handle -> ProducerComponent IO Text ()
fromHandle handle = atomic "fromHandle" ioCost (Primitive.fromHandle handle)

-- ** I/O consumers

-- | ConsumerComponent 'toStdOut' copies the given source into the standard output.
toStdOut :: ConsumerComponent IO Text ()
toStdOut = atomic "toStdOut" ioCost Primitive.toStdOut

-- | ConsumerComponent 'toFile' opens the named file and copies the given source into it.
toFile :: String -> ConsumerComponent IO Text ()
toFile path = atomic "toFile" ioCost (Primitive.toFile path)

-- | ConsumerComponent 'appendFile' opens the name file and appends the given source to it.
appendFile :: String -> ConsumerComponent IO Text ()
appendFile path = atomic "appendFile" ioCost (Primitive.appendFile path)

-- | ConsumerComponent 'toHandle' copies the given source into the open file /handle/.
toHandle :: Handle -> ConsumerComponent IO Text ()
toHandle handle = atomic "toHandle" ioCost (Primitive.toHandle handle)

-- * Generic components

-- | 'produceFrom' produces the contents of the given argument.
produceFrom :: (Monad m, MonoidNull x) => x -> ProducerComponent m x ()
produceFrom l = atomic "produceFrom" 1 (Primitive.produceFrom l)
   
-- ** Generic consumers

-- | ConsumerComponent 'consumeInto' collects the given source into the return value.
consumeInto :: (Monad m, Monoid x) => ConsumerComponent m x x
consumeInto = atomic "consumeInto" 1 Primitive.consumeInto

-- | The 'suppress' consumer suppresses all input it receives. It is equivalent to 'substitute' []
suppress :: Monad m => ConsumerComponent m x ()
suppress = atomic "suppress" 1 Primitive.suppress

-- | The 'erroneous' consumer reports an error if any input reaches it.
erroneous :: (Monad m, MonoidNull x) => String -> ConsumerComponent m x ()
erroneous message = atomic "erroneous" 0 (Primitive.erroneous message)

-- ** Generic transducers

-- | TransducerComponent 'id' passes its input through unmodified.
id :: (Monad m, Monoid x) => TransducerComponent m x x
id = atomic "id" 1 $ Transducer pour_

-- | TransducerComponent 'unparse' removes all markup from its input and passes the content through.
unparse :: (Monad m, Monoid x) => TransducerComponent m [Markup b x] x
unparse = atomic "unparse" 1 Primitive.unparse

-- | TransducerComponent 'parse' prepares input content for subsequent parsing.
parse :: (Monad m, Monoid x) => ParserComponent m x y
parse = atomic "parse" 1 Primitive.parse

-- | The 'lowercase' transforms all uppercase letters in the input to lowercase, leaving the rest unchanged.
lowercase :: Monad m => TransducerComponent m String String
lowercase = atomic "lowercase" 1 Primitive.lowercase

-- | The 'uppercase' transforms all lowercase letters in the input to uppercase, leaving the rest unchanged.
uppercase :: Monad m => TransducerComponent m String String
uppercase = atomic "uppercase" 1 Primitive.uppercase

-- | The 'count' transducer counts all its input values and outputs the final tally.
count :: (Monad m, FactorialMonoid x) => TransducerComponent m x [Integer]
count = atomic "count" 1 Primitive.count

-- | Converts each input value @x@ to @show x@.
toString :: (Monad m, Show x) => TransducerComponent m [x] [String]
toString = atomic "toString" 1 Primitive.toString

-- | Performs the same task as the 'substring' splitter, but instead of splitting it outputs the input as @'Markup' x
-- 'OccurenceTag'@ in order to distinguish overlapping strings.
parseSubstring :: (Monad m, Eq x, LeftCancellativeMonoid x, FactorialMonoid x) => x -> ParserComponent m x OccurenceTag
parseSubstring list = atomic "parseSubstring" 1 (Primitive.parseSubstring list)

-- *** List stream transducers

-- | TransducerComponent 'group' collects all its input into a single list item.
group :: (Monad m, Monoid x) => TransducerComponent m x [x]
group = atomic "group" 1 Primitive.group

-- | TransducerComponent 'concatenate' flattens the input stream of lists of values into the output stream of values.
concatenate :: (Monad m, Monoid x) => TransducerComponent m [x] x
concatenate = atomic "concatenate" 1 Primitive.concatenate

-- | Same as 'concatenate' except it inserts the given separator list between every two input lists.
concatSeparate :: (Monad m, MonoidNull x) => x -> TransducerComponent m [x] x
concatSeparate separator = atomic "concatSeparate" 1 (Primitive.concatSeparate separator)

-- ** Generic splitters

-- | SplitterComponent 'everything' feeds its entire input into its /true/ sink.
everything :: Monad m => SplitterComponent m x
everything = atomic "everything" 1 Primitive.everything

-- | SplitterComponent 'nothing' feeds its entire input into its /false/ sink.
nothing :: (Monad m, Monoid x) => SplitterComponent m x
nothing = atomic "nothing" 1 Primitive.nothing

-- | SplitterComponent 'marked' passes all marked-up input sections to its /true/ sink, and all unmarked input to its
-- /false/ sink.
marked :: (Monad m, Eq y) => SplitterComponent m [Markup y x]
marked = atomic "marked" 1 Primitive.marked

-- | SplitterComponent 'markedContent' passes the content of all marked-up input sections to its /true/ sink, while the
-- outermost tags and all unmarked input go to its /false/ sink.
markedContent :: (Monad m, Eq y) => SplitterComponent m [Markup y x]
markedContent = atomic "markedContent" 1 Primitive.markedContent

-- | SplitterComponent 'markedWith' passes input sections marked-up with the appropriate tag to its /true/ sink, and the
-- rest of the input to its /false/ sink. The argument /select/ determines if the tag is appropriate.
markedWith :: (Monad m, Eq y) => (y -> Bool) -> SplitterComponent m [Markup y x]
markedWith selector = atomic "markedWith" 1 (Primitive.markedWith selector)

-- | SplitterComponent 'contentMarkedWith' passes the content of input sections marked-up with the appropriate tag to
-- its /true/ sink, and the rest of the input to its /false/ sink. The argument /select/ determines if the tag is
-- appropriate.
contentMarkedWith :: (Monad m, Eq y) => (y -> Bool) -> SplitterComponent m [Markup y x]
contentMarkedWith selector = atomic "contentMarkedWith" 1 (Primitive.contentMarkedWith selector)

-- | SplitterComponent 'one' feeds all input values to its /true/ sink, treating every value as a separate section.
one :: (Monad m, FactorialMonoid x) => SplitterComponent m x
one = atomic "one" 1 Primitive.one

-- | SplitterComponent 'substring' feeds to its /true/ sink all input parts that match the contents of the given list
-- argument. If two overlapping parts of the input both match the argument, both are sent to /true/ and each is preceded
-- by an empty chunk on /false/.
substring :: (Monad m, Eq x, LeftCancellativeMonoid x, FactorialMonoid x) => x -> SplitterComponent m x
substring list = atomic "substring" 1 (Primitive.substring list)

-- * Character stream components

-- | SplitterComponent 'whitespace' feeds all white-space characters into its /true/ sink, all others into /false/.
whitespace :: Monad m => SplitterComponent m String
whitespace = atomic "whitespace" 1 Primitive.whitespace

-- | SplitterComponent 'letters' feeds all alphabetical characters into its /true/ sink, all other characters into
-- | /false/.
letters :: Monad m => SplitterComponent m String
letters = atomic "letters" 1 Primitive.letters

-- | SplitterComponent 'digits' feeds all digits into its /true/ sink, all other characters into /false/.
digits :: Monad m => SplitterComponent m String
digits = atomic "digits" 1 Primitive.digits

-- | SplitterComponent 'nonEmptyLine' feeds line-ends into its /false/ sink, and all other characters into /true/.
nonEmptyLine :: Monad m => SplitterComponent m String
nonEmptyLine = atomic "nonEmptyLine" 1 Primitive.nonEmptyLine

-- | The sectioning splitter 'line' feeds line-ends into its /false/ sink, and line contents into /true/. A single
-- line-end can be formed by any of the character sequences \"\\n\", \"\\r\", \"\\r\\n\", or \"\\n\\r\".
line :: Monad m => SplitterComponent m String
line = atomic "line" 1 Primitive.line

-- * Consumer, producer, and transducer combinators

-- | Converts a 'ConsumerComponent' into a 'TransducerComponent' with no output.
consumeBy :: (Monad m) => ConsumerComponent m x r -> TransducerComponent m x y
consumeBy = Configuration.lift 1 "consumeBy" Combinator.consumeBy

-- | Class 'PipeableComponentPair' applies to any two components that can be combined into a third component with the
-- following properties:
--
--    * The input of the result, if any, becomes the input of the first component.
--
--    * The output produced by the first child component is consumed by the second child component.
--
--    * The result output, if any, is the output of the second component.

(>->) :: (MonadParallel m, PipeableComponentPair m w c1 c2 c3) => 
         Component c1 -> Component c2 -> Component c3
(>->) = liftParallelPair ">->" compose

class CompatibleSignature c cons (m :: * -> *) input output | c -> cons m

class AnyListOrUnit c

instance AnyListOrUnit [x]
instance AnyListOrUnit ()

instance (AnyListOrUnit x, AnyListOrUnit y) => CompatibleSignature (Performer m r)    (PerformerType r)  m x y
instance AnyListOrUnit y                    => CompatibleSignature (Consumer m x r)   (ConsumerType r)   m [x] y
instance AnyListOrUnit y                    => CompatibleSignature (Producer m x r)   (ProducerType r)   m y [x]
instance                                       CompatibleSignature (Transducer m x y)  TransducerType    m [x] [y]

data PerformerType r
data ConsumerType r
data ProducerType r
data TransducerType

-- | Class 'JoinableComponentPair' applies to any two components that can be combined into a third component with the
-- following properties:
--
--    * if both argument components consume input, the input of the combined component gets distributed to both
--      components in parallel,
--
--    * if both argument components produce output, the output of the combined component is a concatenation of the
--      complete output from the first component followed by the complete output of the second component, and

-- | The 'join' combinator may apply the components in any order.
join :: (MonadParallel m, Combinator.JoinableComponentPair t1 t2 t3 m x y c1 c2 c3) => 
        Component c1 -> Component c2 -> Component c3
join = liftParallelPair "join" Combinator.join

-- | The 'sequence' combinator makes sure its first argument has completed before using the second one.
sequence :: Combinator.JoinableComponentPair t1 t2 t3 m x y c1 c2 c3 => Component c1 -> Component c2 -> Component c3
sequence = Configuration.liftSequentialPair "sequence" Combinator.sequence

-- | Combinator 'prepend' converts the given producer to transducer that passes all its input through unmodified, except
-- | for prepending the output of the argument producer to it.
-- | 'prepend' /prefix/ = 'join' ('substitute' /prefix/) 'asis'
prepend :: (Monad m) => ProducerComponent m x r -> TransducerComponent m x x
prepend = Configuration.lift 1 "prepend" Combinator.prepend

-- | Combinator 'append' converts the given producer to transducer that passes all its input through unmodified, finally
-- | appending to it the output of the argument producer.
-- | 'append' /suffix/ = 'join' 'asis' ('substitute' /suffix/)
append :: (Monad m) => ProducerComponent m x r -> TransducerComponent m x x
append = Configuration.lift 1 "append" Combinator.append

-- | The 'substitute' combinator converts its argument producer to a transducer that produces the same output, while
-- | consuming its entire input and ignoring it.
substitute :: (Monad m, Monoid x) => ProducerComponent m y r -> TransducerComponent m x y
substitute = Configuration.lift 1 "substitute" Combinator.substitute

-- * Splitter combinators

-- | The 'snot' (streaming not) combinator simply reverses the outputs of the argument splitter. In other words, data
-- that the argument splitter sends to its /true/ sink goes to the /false/ sink of the result, and vice versa.
snot :: (Monad m, Monoid x) => SplitterComponent m x -> SplitterComponent m x
snot = Configuration.lift 1 "not" Combinator.sNot

-- ** Pseudo-logic flow combinators

-- | The '>&' combinator sends the /true/ sink output of its left operand to the input of its right operand for further
-- splitting. Both operands' /false/ sinks are connected to the /false/ sink of the combined splitter, but any input
-- value to reach the /true/ sink of the combined component data must be deemed true by both splitters.
(>&) :: (MonadParallel m, Monoid x) => SplitterComponent m x -> SplitterComponent m x -> SplitterComponent m x
(>&) = liftParallelPair ">&" Combinator.sAnd

-- | A '>|' combinator's input value can reach its /false/ sink only by going through both argument splitters' /false/
-- sinks.
(>|) :: (MonadParallel m, Monoid x) => SplitterComponent m x -> SplitterComponent m x -> SplitterComponent m x
(>|) = liftParallelPair ">&" Combinator.sOr

-- ** Zipping logic combinators

-- | Combinator '&&' is a pairwise logical conjunction of two splitters run in parallel on the same input.
(&&) :: (MonadParallel m, FactorialMonoid x) => SplitterComponent m x -> SplitterComponent m x -> SplitterComponent m x
(&&) = liftParallelPair "&&" Combinator.pAnd

-- | Combinator '||' is a pairwise logical disjunction of two splitters run in parallel on the same input.
(||) :: (MonadParallel m, FactorialMonoid x) => SplitterComponent m x -> SplitterComponent m x -> SplitterComponent m x
(||) = liftParallelPair "||" Combinator.pOr

-- * Flow-control combinators

ifs :: (MonadParallel m, Branching c m x ()) => SplitterComponent m x -> Component c -> Component c -> Component c
ifs = parallelRouterAndBranches "ifs" Combinator.ifs

wherever :: (MonadParallel m, Monoid x) =>
            TransducerComponent m x x -> SplitterComponent m x -> TransducerComponent m x x
wherever = liftParallelPair "wherever" Combinator.wherever

unless :: (MonadParallel m, Monoid x) =>
          TransducerComponent m x x -> SplitterComponent m x -> TransducerComponent m x x
unless = liftParallelPair "unless" Combinator.unless

select :: (Monad m, Monoid x) => SplitterComponent m x -> TransducerComponent m x x
select = Configuration.lift 1 "select" Combinator.select

-- ** Recursive

-- | The recursive combinator 'while' feeds the true sink of the argument splitter back to itself, modified by the
-- argument transducer. Data fed to the splitter's false sink is passed on unmodified.
while :: (MonadParallel m, MonoidNull x) =>
         TransducerComponent m x x -> SplitterComponent m x -> TransducerComponent m x x
while t s = recursiveComponentTree "while" (\binder-> uncurry (Combinator.while binder)) $
            Configuration.liftSequentialPair "pair" (,) t s

-- | The recursive combinator 'nestedIn' combines two splitters into a mutually recursive loop acting as a single
-- splitter.  The true sink of one of the argument splitters and false sink of the other become the true and false sinks
-- of the loop.  The other two sinks are bound to the other splitter's source.  The use of 'nestedIn' makes sense only
-- on hierarchically structured streams. If we gave it some input containing a flat sequence of values, and assuming
-- both component splitters are deterministic and stateless, an input value would either not loop at all or it would
-- loop forever.
nestedIn :: (MonadParallel m, MonoidNull x) => SplitterComponent m x -> SplitterComponent m x -> SplitterComponent m x
nestedIn s1 s2 = recursiveComponentTree "nestedIn" (\binder-> uncurry (Combinator.nestedIn binder)) $
                 Configuration.liftSequentialPair "pair" (,) s1 s2

-- * Section-based combinators

-- | The 'foreach' combinator is similar to the combinator 'ifs' in that it combines a splitter and two transducers into
-- another transducer. However, in this case the transducers are re-instantiated for each consecutive portion of the
-- input as the splitter chunks it up. Each contiguous portion of the input that the splitter sends to one of its two
-- sinks gets transducered through the appropriate argument transducer as that transducer's whole input. As soon as the
-- contiguous portion is finished, the transducer gets terminated.
foreach :: (MonadParallel m, MonoidNull x, Branching c m x ()) =>
           SplitterComponent m x -> Component c -> Component c -> Component c
foreach = parallelRouterAndBranches "foreach" Combinator.foreach

-- | The 'having' combinator combines two pure splitters into a pure splitter. One splitter is used to chunk the input
-- into contiguous portions. Its /false/ sink is routed directly to the /false/ sink of the combined splitter. The
-- second splitter is instantiated and run on each portion of the input that goes to first splitter's /true/ sink. If
-- the second splitter sends any output at all to its /true/ sink, the whole input portion is passed on to the /true/
-- sink of the combined splitter, otherwise it goes to its /false/ sink.
having :: (MonadParallel m, MonoidNull x, MonoidNull y, Coercible x y) =>
          SplitterComponent m x -> SplitterComponent m y -> SplitterComponent m x
having = liftParallelPair "having" Combinator.having

-- | The 'havingOnly' combinator is analogous to the 'having' combinator, but it succeeds and passes each chunk of the
-- input to its /true/ sink only if the second splitter sends no part of it to its /false/ sink.
havingOnly :: (MonadParallel m, MonoidNull x, MonoidNull y, Coercible x y) =>
              SplitterComponent m x -> SplitterComponent m y -> SplitterComponent m x
havingOnly = liftParallelPair "havingOnly" Combinator.havingOnly

-- | Combinator 'followedBy' treats its argument 'SplitterComponent's as patterns components and returns a
-- 'SplitterComponent' that matches their concatenation. A section of input is considered /true/ by the result iff its
-- prefix is considered /true/ by argument /s1/ and the rest of the section is considered /true/ by /s2/. The splitter
-- /s2/ is started anew after every section split to /true/ sink by /s1/.
followedBy :: (MonadParallel m, FactorialMonoid x) =>
              SplitterComponent m x -> SplitterComponent m x -> SplitterComponent m x
followedBy = liftParallelPair "followedBy" Combinator.followedBy

-- | The 'even' combinator takes every input section that its argument /splitter/ deems /true/, and feeds even ones into
-- its /true/ sink. The odd sections and parts of input that are /false/ according to its argument splitter are fed to
-- 'even' splitter's /false/ sink.
even :: (Monad m, MonoidNull x) => SplitterComponent m x -> SplitterComponent m x
even = Configuration.lift 2 "even" Combinator.even

-- ** first and its variants

-- | The result of combinator 'first' behaves the same as the argument splitter up to and including the first portion of
-- the input which goes into the argument's /true/ sink. All input following the first true portion goes into the
-- /false/ sink.
first :: (Monad m, MonoidNull x) => SplitterComponent m x -> SplitterComponent m x
first = Configuration.lift 2 "first" Combinator.first

-- | The result of combinator 'uptoFirst' takes all input up to and including the first portion of the input which goes
-- into the argument's /true/ sink and feeds it to the result splitter's /true/ sink. All the rest of the input goes
-- into the /false/ sink. The only difference between 'first' and 'uptoFirst' combinators is in where they direct the
-- /false/ portion of the input preceding the first /true/ part.
uptoFirst :: (Monad m, MonoidNull x) => SplitterComponent m x -> SplitterComponent m x
uptoFirst = Configuration.lift 2 "uptoFirst" Combinator.uptoFirst

-- | The 'prefix' combinator feeds its /true/ sink only the prefix of the input that its argument feeds to its /true/
-- sink.  All the rest of the input is dumped into the /false/ sink of the result.
prefix :: (Monad m, MonoidNull x) => SplitterComponent m x -> SplitterComponent m x
prefix = Configuration.lift 2 "prefix" Combinator.prefix

-- ** last and its variants

-- | The result of the combinator 'last' is a splitter which directs all input to its /false/ sink, up to the last
-- portion of the input which goes to its argument's /true/ sink. That portion of the input is the only one that goes to
-- the resulting component's /true/ sink.  The splitter returned by the combinator 'last' has to buffer the previous two
-- portions of its input, because it cannot know if a true portion of the input is the last one until it sees the end of
-- the input or another portion succeeding the previous one.
last :: (Monad m, MonoidNull x) => SplitterComponent m x -> SplitterComponent m x
last = Configuration.lift 2 "last" Combinator.last

-- | The result of the combinator 'lastAndAfter' is a splitter which directs all input to its /false/ sink, up to the
-- last portion of the input which goes to its argument's /true/ sink. That portion and the remainder of the input is
-- fed to the resulting component's /true/ sink. The difference between 'last' and 'lastAndAfter' combinators is where
-- they feed the /false/ portion of the input, if any, remaining after the last /true/ part.
lastAndAfter :: (Monad m, MonoidNull x) => SplitterComponent m x -> SplitterComponent m x
lastAndAfter = Configuration.lift 2 "lastAndAfter" Combinator.lastAndAfter

-- | The 'suffix' combinator feeds its /true/ sink only the suffix of the input that its argument feeds to its /true/
-- sink.  All the rest of the input is dumped into the /false/ sink of the result.
suffix :: (Monad m, MonoidNull x) => SplitterComponent m x -> SplitterComponent m x
suffix = Configuration.lift 2 "suffix" Combinator.suffix

-- ** positional splitters

-- | SplitterComponent 'startOf' issues an empty /true/ section at the beginning of every section considered /true/ by
-- its argument splitter, otherwise the entire input goes into its /false/ sink.
startOf :: (Monad m, MonoidNull x) => SplitterComponent m x -> SplitterComponent m x
startOf = Configuration.lift 2 "startOf" Combinator.startOf

-- | SplitterComponent 'endOf' issues an empty /true/ section at the end of every section considered /true/ by its
-- argument splitter, otherwise the entire input goes into its /false/ sink.
endOf :: (Monad m, MonoidNull x) => SplitterComponent m x -> SplitterComponent m x
endOf = Configuration.lift 2 "endOf" Combinator.endOf

-- | Combinator '...' tracks the running balance of difference between the number of preceding starts of sections
-- considered /true/ according to its first argument and the ones according to its second argument. The combinator
-- passes to /true/ all input values for which the difference balance is positive. This combinator is typically used
-- with 'startOf' and 'endOf' in order to count entire input sections and ignore their lengths.
(...) :: (MonadParallel m, FactorialMonoid x) => SplitterComponent m x -> SplitterComponent m x -> SplitterComponent m x
(...) = liftParallelPair "..." Combinator.between

-- * Parser support

-- | Converts a splitter into a parser.
parseRegions :: (Monad m, MonoidNull x) => SplitterComponent m x -> ParserComponent m x ()
parseRegions = Configuration.lift 1 "parseRegions" Combinator.parseRegions

-- * Parsing XML

-- | This splitter splits XML markup from data content. It is used by 'parseXMLTokens'.
xmlTokens :: Monad m => SplitterComponent m Text
xmlTokens = atomic "XML.tokens" 1 XML.xmlTokens

-- | The XML token parser. This parser converts plain text to parsed text, which is a precondition for using the
-- remaining XML components.
xmlParseTokens :: MonadParallel m => TransducerComponent m Text [Markup XMLToken Text]
xmlParseTokens = atomic "XML.parseTokens" 1 XML.parseXMLTokens

-- * XML splitters

-- | Splits all top-level elements with all their content to /true/, all other input to /false/.
xmlElement :: Monad m => SplitterComponent m [Markup XMLToken Text]
xmlElement = atomic "XML.element" 1 XML.xmlElement

-- | Splits the content of all top-level elements to /true/, their tags and intervening input to /false/.
xmlElementContent :: Monad m => SplitterComponent m [Markup XMLToken Text]
xmlElementContent = atomic "XML.elementContent" 1 XML.xmlElementContent

-- | Similiar to @('Control.Concurrent.SCC.Combinators.having' 'element')@, except it runs the argument splitter
-- only on each element's start tag, not on the entire element with its content.
xmlElementHavingTagWith :: MonadParallel m =>
                       SplitterComponent m [Markup XMLToken Text] -> SplitterComponent m [Markup XMLToken Text]
xmlElementHavingTagWith = Configuration.lift 2 "XML.elementHavingTag" XML.xmlElementHavingTagWith

-- | Splits every attribute specification to /true/, everything else to /false/.
xmlAttribute :: Monad m => SplitterComponent m [Markup XMLToken Text]
xmlAttribute = atomic "XML.attribute" 1 XML.xmlAttribute

-- | Splits every element name, including the names of nested elements and names in end tags, to /true/, all the rest of
-- input to /false/.
xmlElementName :: Monad m => SplitterComponent m [Markup XMLToken Text]
xmlElementName = atomic "XML.elementName" 1 XML.xmlElementName

-- | Splits every attribute name to /true/, all the rest of input to /false/.
xmlAttributeName :: Monad m => SplitterComponent m [Markup XMLToken Text]
xmlAttributeName = atomic "XML.attributeName" 1 XML.xmlAttributeName

-- | Splits every attribute value, excluding the quote delimiters, to /true/, all the rest of input to /false/.
xmlAttributeValue :: Monad m => SplitterComponent m [Markup XMLToken Text]
xmlAttributeValue = atomic "XML.attributeValue" 1 XML.xmlAttributeValue

liftParallelPair :: MonadParallel m => 
                    String -> (PairBinder m -> c1 -> c2 -> c3) -> Component c1 -> Component c2 -> Component c3
liftParallelPair name combinator = Configuration.liftParallelPair name (\b-> combinator $ chooseBinder b)

parallelRouterAndBranches :: MonadParallel m => 
                             String -> (PairBinder m -> c1 -> c2 -> c3 -> c4) 
                             -> Component c1 -> Component c2 -> Component c3 -> Component c4
parallelRouterAndBranches name combinator = 
   Configuration.parallelRouterAndBranches name (\b-> combinator $ chooseBinder b)

chooseBinder :: MonadParallel m => Bool -> PairBinder m
chooseBinder parallel = if parallel then parallelBinder else sequentialBinder

recursiveComponentTree :: MonadParallel m => String -> (PairBinder m -> c1 -> c2 -> c2) -> Component c1 -> Component c2
recursiveComponentTree name combinator = Configuration.recursiveComponentTree name (\b-> combinator $ chooseBinder b)
