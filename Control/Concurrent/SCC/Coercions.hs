{- 
    Copyright 2009-2012 Mario Blazevic

    This file is part of the Streaming Component Combinators (SCC) project.

    The SCC project is free software: you can redistribute it and/or modify it under the terms of the GNU General Public
    License as published by the Free Software Foundation, either version 3 of the License, or (at your option) any later
    version.

    SCC is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY; without even the implied warranty
    of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU General Public License for more details.

    You should have received a copy of the GNU General Public License along with SCC.  If not, see
    <http://www.gnu.org/licenses/>.
-}

-- | This module defines class 'Coercible' and its instances.

{-# LANGUAGE Rank2Types, ScopedTypeVariables, MultiParamTypeClasses, 
             FlexibleContexts, FlexibleInstances, IncoherentInstances #-}
{-# OPTIONS_HADDOCK hide #-}

module Control.Concurrent.SCC.Coercions
   (
   -- * Coercible class
      Coercible(..),
   -- * Splitter isomorphism
      adaptSplitter
   )
where

import Prelude hiding ((.))
import Control.Category ((.))
import Control.Monad (liftM)
import Data.Monoid (Monoid(mempty))
import Data.Text (Text, pack, unpack)

import Control.Monad.Coroutine (sequentialBinder)

import Control.Concurrent.SCC.Streams
import Control.Concurrent.SCC.Types


-- | Two streams of 'Coercible' types can be unambigously converted one to another.
class Coercible x y where
   -- | A 'Transducer' that converts a stream of one type to another.
   coerce :: Monad m => Transducer m x y
   adaptConsumer :: (Monad m, Monoid x, Monoid y) => Consumer m y r -> Consumer m x r
   adaptConsumer consumer = isolateConsumer $ \source-> liftM snd $ pipe (transduce coerce source) (consume consumer)
   adaptProducer :: (Monad m, Monoid x, Monoid y) => Producer m x r -> Producer m y r
   adaptProducer producer = isolateProducer $ \sink-> liftM fst $ pipe (produce producer) (flip (transduce coerce) sink)

instance Coercible x x where
   coerce = Transducer pour_
   adaptConsumer = id
   adaptProducer = id

instance Monoid x => Coercible [x] x where
   coerce = statelessTransducer id

instance Coercible [Char] [Text] where
   coerce = Transducer (mapStreamChunks ((:[]) . pack))

instance Coercible String Text where
   coerce = Transducer (mapStreamChunks pack)

instance Coercible [Text] [Char] where
   coerce = statelessTransducer unpack

instance Coercible Text String where
   coerce = statelessChunkTransducer unpack

instance Coercible [x] [y] => Coercible [[x]] [y] where
   coerce = compose sequentialBinder (statelessTransducer id) coerce

instance Coercible [x] [y] => Coercible [Markup b x] [y] where
   coerce = compose sequentialBinder (statelessTransducer unmark) coerce
      where unmark (Content x) = [x]
            unmark (Markup _) = []

instance (Monoid x, Monoid y, Coercible x y) => Coercible [Markup b x] y where
   coerce = compose sequentialBinder (statelessTransducer unmark) coerce
      where unmark (Content x) = x
            unmark (Markup _) = mempty

-- | Adjusts the argument splitter to split the stream of a data type 'Isomorphic' to the type it was meant to split.
adaptSplitter :: forall m x y b. (Monad m, Monoid x, Monoid y, Coercible x y, Coercible y x) =>
                 Splitter m x -> Splitter m y
adaptSplitter sx = 
   isolateSplitter $ \source true false->
   pipe 
      (transduce coerce source) 
      (\source'-> 
        pipe 
           (\true'-> 
             pipe
                (\false'-> split sx source' true' false') 
                (flip (transduce coerce) false))
           (flip (transduce coerce) true))
      >> return ()
