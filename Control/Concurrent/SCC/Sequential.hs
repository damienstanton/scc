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

-- | This module exports the entire SCC library except for low-level modules "Control.Concurrent.SCC.Streams" and
-- "Control.Concurrent.SCC.Types". The exported combinators run their components by sequentially interleaving them.

module Control.Concurrent.SCC.Sequential (
   module Control.Concurrent.SCC.Coercions,
   module Control.Concurrent.SCC.Primitives,
   module Control.Concurrent.SCC.Combinators.Sequential,
   module Control.Concurrent.SCC.XML
)
where

import Control.Concurrent.SCC.Coercions
import Control.Concurrent.SCC.Primitives
import Control.Concurrent.SCC.Combinators.Sequential
import Control.Concurrent.SCC.XML
