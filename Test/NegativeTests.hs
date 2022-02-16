{- 
    Copyright 2008-2010 Mario Blazevic

    This file is part of the Streaming Component Combinators (SCC) project.

    The SCC project is free software: you can redistribute it and/or modify it under the terms of the GNU General Public
    License as published by the Free Software Foundation, either version 3 of the License, or (at your option) any later
    version.

    SCC is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY; without even the implied warranty
    of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU General Public License for more details.

    You should have received a copy of the GNU General Public License along with SCC.  If not, see
    <http://www.gnu.org/licenses/>.
-}

-- | Module "NegativeTests" is not supposed to compile. There should be a compile error on each line starting with "test[0-9]* =".

module Main where

import Control.Concurrent.SCC.Trampoline
import Data.Functor.Identity (Identity, runIdentity)

test1 = put $ snd $ runIdentity $ pipe (\sink-> return sink) (\source-> undefined source)


test2 = get $ fst $ runIdentity $ pipe (\sink-> undefined sink) (\source-> return source)

test3 :: Identity (Bool, ())
test3 = pipe (\sink-> return $ runIdentity $ put sink ()) (\source-> liftBounce (return () :: Identity ()))

test4 :: Identity ((), Maybe Integer)
test4 = pipe (\sink-> liftBounce $ return ()) (\source-> return $ runIdentity $ get source)

test5 :: Identity (Bool, ())
test5 = pipe (\sink-> put sink sink) (\source-> get source >> return ())

main = do print (runIdentity test3)
          print (runIdentity test4)
