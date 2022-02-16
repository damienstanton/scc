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

{-# LANGUAGE Rank2Types, FlexibleContexts #-}
{-# OPTIONS_HADDOCK hide #-}

-- | This module exports parallel versions of the combinators from the "Control.Concurrent.SCC.Combinators" module.

module Control.Concurrent.SCC.Combinators.Parallel (
   -- * Consumer, producer, and transducer combinators
   Combinators.consumeBy, Combinators.prepend, Combinators.append, Combinators.substitute,
   PipeableComponentPair, (>->), Combinators.JoinableComponentPair (Combinators.sequence), join,
   -- * Splitter combinators
   Combinators.sNot,
   -- ** Pseudo-logic flow combinators
   -- | Combinators '>&' and '>|' are only /pseudo/-logic. While the laws of double negation and De Morgan's laws
   -- hold, 'sAnd' and 'sOr' are in general not commutative, associative, nor idempotent. In the special case when all
   -- argument splitters are stateless, such as those produced by 'Control.Concurrent.SCC.Types.statelessSplitter',
   -- these combinators do satisfy all laws of Boolean algebra.
   (>&), (>|),
   -- ** Zipping logic combinators
   -- | The '&&' and '||' combinators run the argument splitters in parallel and combine their logical outputs using
   -- the corresponding logical operation on each output pair, in a manner similar to 'Data.List.zipWith'. They fully
   -- satisfy the laws of Boolean algebra.
   (&&), (||),
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
   ifs, wherever, unless, Combinators.select,
   -- ** Recursive
   while, nestedIn,
   -- * Section-based combinators
   -- | All combinators in this section use their 'Control.Concurrent.SCC.Splitter' argument to determine the structure
   -- of the input. Every contiguous portion of the input that gets passed to one or the other sink of the splitter is
   -- treated as one section in the logical structure of the input stream. What is done with the section depends on the
   -- combinator, but the sections, and therefore the logical structure of the input stream, are determined by the
   -- argument splitter alone.
   foreach, having, havingOnly, followedBy, Combinators.even,
   -- ** first and its variants
   Combinators.first, Combinators.uptoFirst, Combinators.prefix,
   -- ** last and its variants
   Combinators.last, Combinators.lastAndAfter, Combinators.suffix,
   -- ** positional splitters
   Combinators.startOf, Combinators.endOf, (...),
   -- * Parser support
   Combinators.splitterToMarker, Combinators.parseRegions,
   )
where

import Prelude hiding ((&&), (||), even, last, sequence)
import Data.Monoid (Monoid)
import Data.Text (Text)

import Control.Monad.Parallel (MonadParallel)
import Control.Monad.Coroutine (parallelBinder)
import Data.Monoid.Null (MonoidNull)
import Data.Monoid.Factorial (FactorialMonoid)

import Control.Concurrent.SCC.Types
import Control.Concurrent.SCC.Coercions (Coercible)
import qualified Control.Concurrent.SCC.Combinators as Combinators
import qualified Control.Concurrent.SCC.XML as XML

-- | Class 'PipeableComponentPair' applies to any two components that can be combined into a third component with the
-- following properties:
--
--    * The input of the result, if any, becomes the input of the first component.
--
--    * The output produced by the first child component is consumed by the second child component.
--
--    * The result output, if any, is the output of the second component.
(>->) :: (MonadParallel m, PipeableComponentPair m w c1 c2 c3) => c1 -> c2 -> c3
(>->) = compose parallelBinder

-- | The 'join' combinator may apply the components in any order.
join :: (MonadParallel m, Combinators.JoinableComponentPair t1 t2 t3 m x y c1 c2 c3) => c1 -> c2 -> c3
join = Combinators.join parallelBinder

-- | The '>&' combinator sends the /true/ sink output of its left operand to the input of its right operand for further
-- splitting. Both operands' /false/ sinks are connected to the /false/ sink of the combined splitter, but any input
-- value to reach the /true/ sink of the combined component data must be deemed true by both splitters.
(>&) :: (MonadParallel m, Monoid x) => Splitter m x -> Splitter m x -> Splitter m x
(>&) = Combinators.sAnd parallelBinder

-- | A '>|' combinator's input value can reach its /false/ sink only by going through both argument splitters' /false/
-- sinks.
(>|) :: (MonadParallel m, Monoid x) => Splitter m x -> Splitter m x -> Splitter m x 
(>|) =  Combinators.sOr parallelBinder

-- | Combinator '&&' is a pairwise logical conjunction of two splitters run in parallel on the same input.
(&&) :: (MonadParallel m, FactorialMonoid x) => Splitter m x -> Splitter m x -> Splitter m x
(&&) = Combinators.pAnd parallelBinder

-- | Combinator '||' is a pairwise logical disjunction of two splitters run in parallel on the same input.
(||) :: (MonadParallel m, FactorialMonoid x) => Splitter m x -> Splitter m x -> Splitter m x
(||) = Combinators.pOr parallelBinder

ifs :: (MonadParallel m, Monoid x, Branching c m x ()) => Splitter m x -> c -> c -> c
ifs = Combinators.ifs parallelBinder

wherever :: (MonadParallel m, Monoid x) => Transducer m x x -> Splitter m x -> Transducer m x x
wherever = Combinators.wherever parallelBinder

unless :: (MonadParallel m, Monoid x) => Transducer m x x -> Splitter m x -> Transducer m x x
unless = Combinators.unless parallelBinder

-- | The recursive combinator 'while' feeds the true sink of the argument splitter back to itself, modified by the
-- argument transducer. Data fed to the splitter's false sink is passed on unmodified.
while :: (MonadParallel m, MonoidNull x) => Transducer m x x -> Splitter m x -> Transducer m x x
while t s = Combinators.while parallelBinder t s (while t s)

-- | The recursive combinator 'nestedIn' combines two splitters into a mutually recursive loop acting as a single
-- splitter. The true sink of one of the argument splitters and false sink of the other become the true and false sinks
-- of the loop. The other two sinks are bound to the other splitter's source. The use of 'nestedIn' makes sense only on
-- hierarchically structured streams. If we gave it some input containing a flat sequence of values, and assuming both
-- component splitters are deterministic and stateless, an input value would either not loop at all or it would loop
-- forever.
nestedIn :: (MonadParallel m, MonoidNull x) => Splitter m x -> Splitter m x -> Splitter m x
nestedIn s1 s2 = Combinators.nestedIn parallelBinder s1 s2 (nestedIn s1 s2)

-- | The 'foreach' combinator is similar to the combinator 'ifs' in that it combines a splitter and two transducers into
-- another transducer. However, in this case the transducers are re-instantiated for each consecutive portion of the
-- input as the splitter chunks it up. Each contiguous portion of the input that the splitter sends to one of its two
-- sinks gets transducered through the appropriate argument transducer as that transducer's whole input. As soon as the
-- contiguous portion is finished, the transducer gets terminated.
foreach :: (MonadParallel m, MonoidNull x, Branching c m x ()) => Splitter m x -> c -> c -> c
foreach = Combinators.foreach parallelBinder

-- | The 'having' combinator combines two pure splitters into a pure splitter. One splitter is used to chunk the input
-- into contiguous portions. Its /false/ sink is routed directly to the /false/ sink of the combined splitter. The
-- second splitter is instantiated and run on each portion of the input that goes to first splitter's /true/ sink. If
-- the second splitter sends any output at all to its /true/ sink, the whole input portion is passed on to the /true/
-- sink of the combined splitter, otherwise it goes to its /false/ sink.
having :: (MonadParallel m, MonoidNull x, MonoidNull y, Coercible x y) => Splitter m x -> Splitter m y -> Splitter m x
having = Combinators.having parallelBinder

-- | The 'havingOnly' combinator is analogous to the 'having' combinator, but it succeeds and passes each chunk of the
-- input to its /true/ sink only if the second splitter sends no part of it to its /false/ sink.
havingOnly :: (MonadParallel m, MonoidNull x, MonoidNull y, Coercible x y) => 
              Splitter m x -> Splitter m y -> Splitter m x
havingOnly = Combinators.havingOnly parallelBinder

-- | Combinator 'followedBy' treats its argument 'Splitter's as patterns components and returns a 'Splitter' that
-- matches their concatenation. A section of input is considered /true/ by the result iff its prefix is considered
-- /true/ by argument /s1/ and the rest of the section is considered /true/ by /s2/. The splitter /s2/ is started anew
-- after every section split to /true/ sink by /s1/.
followedBy :: (MonadParallel m, FactorialMonoid x) => Splitter m x -> Splitter m x -> Splitter m x
followedBy = Combinators.followedBy parallelBinder

-- | Combinator '...' tracks the running balance of difference between the number of preceding starts of sections
-- considered /true/ according to its first argument and the ones according to its second argument. The combinator
-- passes to /true/ all input values for which the difference balance is positive. This combinator is typically used
-- with 'startOf' and 'endOf' in order to count entire input sections and ignore their lengths.
(...) :: (MonadParallel m, FactorialMonoid x) => Splitter m x -> Splitter m x -> Splitter m x
(...) = Combinators.between parallelBinder
