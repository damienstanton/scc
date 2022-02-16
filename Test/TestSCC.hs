{- 
    Copyright 2008-2012 Mario Blazevic

    This file is part of the Streaming Component Combinators (SCC) project.

    The SCC project is free software: you can redistribute it and/or modify it under the terms of the GNU General Public
    License as published by the Free Software Foundation, either version 3 of the License, or (at your option) any later
    version.

    SCC is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY; without even the implied warranty
    of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU General Public License for more details.

    You should have received a copy of the GNU General Public License along with SCC.  If not, see
    <http://www.gnu.org/licenses/>.
-}

{-# LANGUAGE FlexibleInstances, ScopedTypeVariables #-}

module Main where

import Prelude hiding (even, id, last)
import qualified Prelude

import Control.Monad (liftM, when)
import Data.Char (ord, isLetter, isSpace, toUpper)
import Data.Either (rights)
import Data.Functor.Identity (Identity (Identity, runIdentity))
import Data.List (find, findIndices, groupBy, intersect, union,
                  intercalate, isInfixOf, isPrefixOf, isSuffixOf, nub, sort, tails)
import Data.Maybe (fromJust, isJust, mapMaybe)
import Data.Monoid (Monoid)
import Data.Monoid.Null (MonoidNull)
import qualified Data.List as List
import qualified Data.Foldable as Foldable
import qualified Data.Sequence as Seq
import Data.Sequence (Seq, (|>), (><), ViewL (EmptyL, (:<)))
import Data.String (IsString(fromString))

import Test.QuickCheck (Arbitrary, Gen, Property, CoArbitrary,
                        Positive(Positive), NonNegative(NonNegative), NonEmptyList(NonEmpty),
                        arbitrary, coarbitrary, label, classify, choose, mapSize, oneof, resize, sized,
                        quickCheck, variant, (==>))

import Control.Concurrent.Configuration
import Control.Monad.Coroutine
import Control.Concurrent.SCC.Streams
import Control.Concurrent.SCC.Types
import qualified Control.Concurrent.SCC.Combinators as Combinator
import Control.Concurrent.SCC.Configurable hiding ((&&), (||))
import qualified Control.Concurrent.SCC.XML as XML
import qualified Control.Concurrent.SCC.Configurable as C


sublists [] _ = []
sublists _ [] = []
sublists sublist input = map
                           (input !!)
                           (nub $ sort $ concatMap
                                            (\n-> [n .. n + length sublist - 1])
                                            (findIndices (isPrefixOf sublist) (tails input)))

contentIn :: [Markup y x] -> [x]
contentIn = mapMaybe (\x-> case x of {Content y -> Just y; _ -> Nothing})

both f (x, y) = (f x, f y)

main = mapM_ quickCheck tests

tests = [label "pipe" $ \(input :: [Int])-> runCoroutine (pipe (putAll input) getAll) == Just ([], input),
         label "pour" prop_pour,
         label "id" prop_id,
         label "suppress" prop_suppress,
         label "substitute" prop_substitute,
         label "prepend" prop_prepend,
         label "append" prop_append,
         label "everything" prop_allTrue,
         label "nothing" prop_allFalse,
         label "substring" prop_substring,
         label "group" prop_group,
         label "concatenate" prop_concatenate,
         label "concatSeparate" prop_concatSeparate,
         label "uppercase ->>" $ \s-> runCoroutine (pipe
                                                        (putAll s)
                                                        (consume $ with $
                                                         uppercase >-> atomic "getAll" 1 (Consumer getAll)))
                  == Just ([], map toUpper s),
         label "uppercase <<-" $ \s-> runCoroutine (pipe
                                                        (produce $ with $
                                                         atomic "putAll" 1 (Producer (putAll s)) >-> uppercase)
                                                        getAll)
                  == Just ([], map toUpper s),
         label "uppercase `join` id" $ \s-> transducerOutput (uppercase `join` id) s == map toUpper s ++ s,
         label "prepend >-> append" (\(s :: String) prefix suffix->
                                     transducerOutput (prepend (produceFrom prefix) >-> append (produceFrom suffix)) s
                                     == prefix ++ s ++ suffix),
         label "prepend == (`join` id) . substitute" $
               \(s :: String) prefix-> transducerOutput (prepend (produceFrom prefix)) s
                                       == transducerOutput (substitute (produceFrom prefix) `join` id) s,
         label "append == (id `join`) . substitute" $
               \(s :: String) suffix-> transducerOutput (append (produceFrom suffix)) s
                                       == transducerOutput (id `join` substitute (produceFrom suffix)) s,
         label "whitespace" $ \s-> splitterOutputs whitespace s == (filter isSpace s, filter (not . isSpace) s),
         label "ifs everything id id" $ \(s :: [TestEnum])-> transducerOutput (ifs everything id id) s == s,
         label "substring" $ \s (c :: TestEnum)-> splitterOutputs (substring [c]) s == (filter (==c) s, filter (/=c) s),
         label "line" $ \words-> let words' = map (map letterChar) words
                                 in splitterOutputs line (unlines words') 
                                    == (concat words', replicate (length words) '\n'),
         label "ifs (substring X) uppercase id" $
               \s (LowercaseLetter c)-> transducerOutput (ifs (substring [c]) uppercase id) s
                                        == map (\x-> if x == c then toUpper x else x) s,
         label "parseSubstring" $ \s (c :: TestEnum)-> transducerOutput
                                                          (parseSubstring [c] >-> select markedContent >-> unparse)
                                                          s
                                                       == filter (==c) s,
         label "uppercase `wherever` parseSubstring" $
               \s (LowercaseLetter c)-> transducerOutput
                                           (parseSubstring [c]
                                            >-> (uppercaseContent `wherever` markedContent)
                                            >-> unparse)
                                           s
                                        == map (\x-> if x == c then toUpper x else x) s,
         label "parseRegions substring == parseSubstring" prop_substringVsParse,
         label "count >-> toString >-> concatenate" $
               \(s :: [TestEnum])-> transducerOutput (count >-> toString >-> concatenate) s == show (length s),
         label "foreach whitespace id (prepend \"[\" >-> append \"]\")" $
               \s-> transducerOutput (foreach whitespace id (prepend (produceFrom "[") >-> append (produceFrom "]"))) s
                    == mapWords (("[" ++) . (++ "]")) s,
         label "foreach whitespace id (count >-> toString >-> concatenate)" $
               \s-> transducerOutput (foreach whitespace id (count >-> toString >-> concatenate)) s
                    == mapWords (show . length) s,
         label "uppercase `wherever` (snot whitespace `having` substring X)" $
               \s1 s2-> not (null s1) && length s1 < length s2 ==> classify (not (s1 `isInfixOf` s2)) "trivial" $
                  transducerOutput (uppercase `wherever` (snot whitespace `having` substring s1)) s2
                  == mapWords (\w-> if s1 `isInfixOf` w then map toUpper w else w) s2,
         label "(uppercase `wherever` (snot whitespace `havingOnly` letters))" $
               \s-> transducerOutput (uppercase `wherever` (snot whitespace `havingOnly` letters)) s
                  == mapWords (\w-> if all isLetter w then map toUpper w else w) s,

         label "select $ substring" (transducerOutput (select $ substring "o, ") "Hello, World!" == "o, "),

         label "(uppercase `wherever` (first letters))"
                  (transducerOutput (uppercase `wherever` (first letters)) "... Hello, World !" == "... HELLO, World !"
                   && transducerOutput (uppercase `wherever` (first letters)) "Hello, World !" == "HELLO, World !"),
         label "(uppercase `wherever` (prefix letters))"
                  (transducerOutput (wherever uppercase (prefix letters)) "... Hello, World !" == "... Hello, World !"
                   && transducerOutput (uppercase `wherever` (prefix letters)) "Hello, World !" == "HELLO, World !"),
         label "(uppercase `wherever` (suffix letters))"
                  (transducerOutput (uppercase `wherever` (suffix letters)) "Hello, World!" == "Hello, World!"
                   && transducerOutput (uppercase `wherever` (suffix letters)) "Hello, World" == "Hello, WORLD"),
         label "(uppercase `wherever` (last letters))"
                  (transducerOutput (uppercase `wherever` (last letters)) "Hello, World!" == "Hello, WORLD!"
                   && transducerOutput (uppercase `wherever` (last letters)) "Hello, World" == "Hello, WORLD"),

         label "(select (prefix letters))" (transducerOutput (select (prefix letters)) "Hello, World!" == "Hello"),
         label "(foreach letters (count >-> toString >-> concatenate) id)"
                  (transducerOutput (foreach letters (count >-> toString >-> concatenate) id) "Hola, Mundo!" == "4, 5!"),
         label "(foreach (letters `having` prefix (substring \"H\")) uppercase id)"
                  (transducerOutput (foreach
                                        (letters `having` prefix (substring "H"))
                                        uppercase
                                        id)
                      "Hello, World! Hola, Mundo!"
                   == "HELLO, World! HOLA, Mundo!"),
         label "(foreach (letters `having` suffix (substring \"o\")) uppercase id)"
                  (transducerOutput (foreach
                                        (letters `having` suffix (substring "o"))
                                        uppercase
                                        id)
                      "Hello, World! Hola, Mundo!"
                   == "HELLO, World! Hola, MUNDO!"),

         label "first one" $ \s-> splitterOutputs (first one) s == if null s then ("", "") else ([head s], tail s),
         label "last one" $ \s-> splitterOutputs (last one) s == if null s then ("", "") else ([List.last s], init s),
         label "prefix one" $ \s-> splitterOutputs (prefix one) s == if null s then ("", "") else ([head s], tail s),
         label "suffix one" $ \s-> splitterOutputs (suffix one) s == if null s then ("", "") else ([List.last s], init s),
         label "uptoFirst one" $ \s-> splitterOutputs (uptoFirst one) s == if null s then ("", "") else ([head s], tail s),
         label "lastAndAfter one" $ \s-> splitterOutputs (lastAndAfter one) s == if null s then ("", "")
                                                                                 else ([List.last s], init s),

         label "snot" $ prop_snot . splitterFromTrace,
         label "DeMorgan 1" $ \trace1 trace2-> prop_DeMorgan1 (splitterFromTrace trace1) (splitterFromTrace trace2),
         label "DeMorgan 2" $ \trace1 trace2-> prop_DeMorgan2 (splitterFromTrace trace1) (splitterFromTrace trace2),
         label "&&" $ \trace1 trace2-> prop_and (splitterFromTrace trace1) (splitterFromTrace trace2),
         label "||" $ \trace1 trace2-> prop_or (splitterFromTrace trace1) (splitterFromTrace trace2),
         label "even" $ prop_even . splitterFromTrace,
         label "prefix 1" $ prop_prefix_1 . splitterFromTrace,
         label "prefix 2" $ prop_prefix_2 . splitterFromTrace,
         label "suffix 1" $ prop_suffix_1 . splitterFromTrace,
         label "suffix 2" $ prop_suffix_2 . splitterFromTrace,
         label "first" $ prop_first . splitterFromTrace,
         label "last" $ prop_last . splitterFromTrace,
         label "uptoFirst" $ prop_uptoFirst . splitterFromTrace,
         label "lastAndAfter" $ prop_lastAndAfter . splitterFromTrace,
         label "followedBy prefix" $
               \trace1 trace2 n-> prop_followedBy1 (splitterFromTrace trace1) (simplestSplitterFromTrace trace2) n,
         label "followedBy startOf everything" $ \trace n-> prop_followedBy2 (splitterFromTrace trace) n,
         label "substring followedBy substring 1" prop_followedBy3,
         label "substring followedBy substring 2" prop_followedBy4,
         label "substring followedBy substring 3" prop_followedBy5,
         label "endOf followedBy U followedBy startOf"
                  $ \trace1 trace2 n-> prop_followedBy6 (splitterFromTrace trace1) (splitterFromTrace trace2) n,
         label "... followedBy ..." prop_followedByBetween,
         label "start ... end"  $ \trace n-> prop_between1 (simpleSplitterFromTrace trace) n,
         label "start everything ... end"  $ \trace n-> prop_between2 (simpleSplitterFromTrace trace) n,

         label "XML.tokens" prop_XMLtokens1,
         label "XML.tokens with attributes" prop_XMLtokens2,
         label "XML.parseTokens >-> select elementContent >-> unparse" prop_XMLtokens3,
         label "XML.parseTokens >-> unparse" prop_XMLtokens4,
         label "nestedIn XML.elementContent" $ mapSize (min 40) prop_nestedInXMLcontent,
         label "select XML.elementContent while XML.element" $ mapSize (min 50) prop_whileXMLelement]


prop_pour :: [Int] -> Bool
prop_pour input = runCoroutine (pipe (putAll input) (\source-> pipe (\sink-> pour_ source sink) getAll))
                  == Just ([], ((), input))

prop_id :: [Int] -> Bool
prop_id input = transducerOutput id input == input

prop_suppress :: [Int] -> Bool
prop_suppress input = null (transducerOutput (consumeBy suppress :: TransducerComponent Identity [Int] [()]) input)

prop_substitute :: [Int] -> [Maybe Int] -> Bool
prop_substitute input replacement = transducerOutput (substitute $ produceFrom replacement) input == replacement

prop_prepend :: [Int] -> [Int] -> Int -> Property
prop_prepend input prefix threads = threads > 0 ==>
                                    transducerOutput (usingThreads (prepend $ produceFrom prefix) threads) input
                                    == prefix ++ input

prop_append :: [Int] -> [Int] -> Int -> Property
prop_append input suffix threads = threads > 0 ==>
                                   transducerOutput (usingThreads (append $ produceFrom suffix) threads) input
                                   == input ++ suffix

prop_allTrue :: [Int] -> Bool
prop_allTrue input = splitterOutputs everything input == (input, [])

prop_allFalse :: [Int] -> Bool
prop_allFalse input = splitterOutputs nothing input == ([], input)

prop_substring :: [TestEnum] -> [TestEnum] -> Property
prop_substring input sublist = classify (not (isInfixOf sublist input)) "trivial"
                                  (transducerOutput (select (substring sublist)) input == sublists sublist input)

prop_substringVsParse :: [TestEnum] -> [TestEnum] -> Property
prop_substringVsParse input sublist = not (null sublist) && length sublist < length input
                                      && not (sublist `isInfixOf` (tail sublist ++ init sublist))
                                      ==> classify (not (sublist `isInfixOf` input)) "trivial"
                                             (transducerOutput (parseRegions (substring sublist)) input
                                              == concatMap unitFromOccurrence (transducerOutput (parseSubstring sublist) input))
   where unitFromOccurrence (Content []) = []
         unitFromOccurrence (Content x) = [Content x]
         unitFromOccurrence (Markup b) = [Markup (fmap (const ()) b)]

prop_group :: [Int] -> Bool
prop_group input = transducerOutput group input == [input]

prop_concatenate :: [[TestEnum]] -> Bool
prop_concatenate input = transducerOutput concatenate input == concat input

prop_concatSeparate :: [[TestEnum]] -> [TestEnum] -> Bool
prop_concatSeparate input separator = transducerOutput (concatSeparate separator) input == intercalate separator input

prop_snot :: SplitterComponent Identity [Int] -> [Int] -> Bool
prop_snot splitter input = splitterOutputs (snot splitter) input == swap (splitterOutputs splitter input)

prop_andAssoc :: SplitterTrace -> SplitterTrace -> SplitterTrace -> [Int] -> Int -> Int -> Property
prop_andAssoc st1 st2 st3 input t1 t2
   = t1 > 0 && t2 > 0
     ==> splitterOutputs (usingThreads (s1 C.&& (s2 C.&& s3)) t1) input
      == splitterOutputs (usingThreads ((s1 C.&& s2) C.&& s3) t2) input
   where s1 = splitterFromTrace st1
         s2 = splitterFromTrace st2
         s3 = splitterFromTrace st3

prop_orAssoc :: SplitterTrace -> SplitterTrace -> SplitterTrace -> [Int] -> Int -> Int -> Property
prop_orAssoc st1 st2 st3 input t1 t2
   = t1 > 0 && t2 > 0
     ==> splitterOutputs (usingThreads (s1 C.|| (s2 C.|| s3)) t1) input
      == splitterOutputs (usingThreads ((s1 C.|| s2) C.|| s3) t2) input
   where s1 = splitterFromTrace st1
         s2 = splitterFromTrace st2
         s3 = splitterFromTrace st3

prop_DeMorgan1 :: SplitterComponent Identity [Int] -> SplitterComponent Identity [Int] -> [Int]
               -> Positive Int -> Positive Int -> Bool
prop_DeMorgan1 s1 s2 input (Positive t1) (Positive t2)
   = splitterOutputs (usingThreads (snot (s1 C.&& s2)) (t1 `mod` 50)) input
      == splitterOutputs (usingThreads (snot s1 C.|| snot s2) (t2 `mod` 50)) input

prop_DeMorgan2 :: SplitterComponent Identity [Int] -> SplitterComponent Identity [Int] -> [Int]
               -> Positive Int -> Positive Int -> Bool
prop_DeMorgan2 s1 s2 input (Positive t1) (Positive t2)
   = splitterOutputs (usingThreads (snot (s1 C.|| s2)) (t1 `mod` 50)) input
     == splitterOutputs (usingThreads (snot s1 C.&& snot s2) (t2 `mod` 50)) input

prop_and :: SplitterComponent Identity [Int] -> SplitterComponent Identity [Int] -> Positive Int -> Bool
prop_and s1 s2 (Positive n) = fst (splitterOutputs (s1 C.&& s2) l)
                              == fst (splitterOutputs s1 l) `intersect` fst (splitterOutputs s2 l)
   where l = [1 .. n `mod` 1000]

prop_or :: SplitterComponent Identity [Int] -> SplitterComponent Identity [Int] -> Positive Int -> Bool
prop_or s1 s2 (Positive n) = fst (splitterOutputs (s1 C.|| s2) l)
                             == sort (fst (splitterOutputs s1 l) `union` fst (splitterOutputs s2 l))
   where l = [1 .. n `mod` 1000]

prop_even :: SplitterComponent Identity [TestEnum] -> [TestEnum] -> Bool
prop_even splitter input = let splitOddEven [] = ([], [])
                               splitOddEven (head:tail) = let (evens, odds) = splitOddEven tail in (head:odds, evens)
                           in fst (splitterOutputs (even splitter) input)
                              == concat (snd $ splitOddEven $
                                         transducerOutput (foreach splitter group (consumeBy suppress)) input)

prop_prefix_1 :: SplitterComponent Identity [TestEnum] -> [TestEnum] -> Bool
prop_prefix_1 splitter input = let (pfx, rest) = splitterOutputs (prefix splitter) input
                                   (true, false) = splitterOutputs splitter input
                               in pfx ++ rest == input && pfx `isPrefixOf` true

prop_prefix_2 :: SplitterComponent Identity [TestEnum] -> [TestEnum] -> Bool
prop_prefix_2 splitter input = let (prefix1, rest1) = splitterOutputs (prefix splitter) input
                               in case splitterOutputChunks splitter input
                                  of (prefix2, True):rest2 -> prefix1 == prefix2 && rest1 == concat (map fst rest2)
                                     (prefix2, False):rest2 -> prefix1 == [] && rest1 == prefix2 ++ concat (map fst rest2)
                                     [] -> prefix1 ++ rest1 == []

prop_suffix_1 :: SplitterComponent Identity [TestEnum] -> [TestEnum] -> Bool
prop_suffix_1 splitter input = let (sfx, rest) = splitterOutputs (suffix splitter) input
                                   (true, false) = splitterOutputs splitter input
                               in rest ++ sfx == input && sfx `isSuffixOf` true

prop_suffix_2 :: SplitterComponent Identity [TestEnum] -> [TestEnum] -> Bool
prop_suffix_2 splitter input = let (suffix1, rest1) = splitterOutputs (suffix splitter) input
                               in case reverse (splitterOutputChunks splitter input)
                                  of (suffix2, True):rest2 -> suffix1 == suffix2
                                                              && rest1 == concat (map fst (reverse rest2))
                                     (suffix2, False):rest2 -> suffix1 == []
                                                               && rest1 == concat (map fst (reverse rest2)) ++ suffix2
                                     [] -> rest1 ++ suffix1 == []

prop_first :: SplitterComponent Identity [TestEnum] -> [TestEnum] -> Bool
prop_first splitter input = let (first1, rest1) = splitterOutputs (first splitter) input
                            in case splitterOutputChunks splitter input
                               of (first2, True):rest2 -> first1 == first2 && rest1 == concat (map fst rest2)
                                  (prefix, False):(first2, True):rest2 -> first1 == first2
                                                                          && rest1 == prefix ++ concat (map fst rest2)
                                  (prefix, False):[] -> first1 == [] && rest1 == prefix
                                  [] -> first1 ++ rest1 == []

prop_last :: SplitterComponent Identity [TestEnum] -> [TestEnum] -> Bool
prop_last splitter input = let (last1, rest1) = splitterOutputs (last splitter) input
                           in -- trace (show (last1, rest1)) $ trace (show (splitterOutputChunks splitter input)) $
                              case reverse (splitterOutputChunks splitter input)
                              of (last2, True):rest2 -> last1 == last2 && rest1 == concat (map fst (reverse rest2))
                                 (suffix, False):(last2, True):rest2
                                    -> last1 == last2 && rest1 == concat (map fst (reverse rest2)) ++ suffix
                                 (suffix, False):[] -> last1 == [] && rest1 == suffix
                                 [] -> last1 ++ rest1 == []

prop_uptoFirst :: SplitterComponent Identity [TestEnum] -> [TestEnum] -> Bool
prop_uptoFirst splitter input = let (first1, rest1) = splitterOutputs (uptoFirst splitter) input
                                in case splitterOutputChunks splitter input
                                   of (first2, True):rest2 -> first1 == first2 && rest1 == concat (map fst rest2)
                                      (prefix, False):(first2, True):rest2 -> first1 == prefix ++ first2
                                                                              && rest1 == concat (map fst rest2)
                                      (prefix, False):[] -> first1 == [] && rest1 == prefix
                                      [] -> first1 ++ rest1 == []

prop_lastAndAfter :: SplitterComponent Identity [TestEnum] -> [TestEnum] -> Bool
prop_lastAndAfter splitter input = let (last1, rest1) = splitterOutputs (lastAndAfter splitter) input
                                   in case reverse (splitterOutputChunks splitter input)
                                      of (last2, True):rest2 -> last1 == last2 && rest1 == concat (map fst (reverse rest2))
                                         (suffix, False):(last2, True):rest2 -> last1 == last2 ++ suffix
                                                                                && rest1 == concat (map fst (reverse rest2))
                                         (suffix, False):[] -> last1 == [] && rest1 == suffix
                                         [] -> last1 ++ rest1 == []

prop_followedBy1 :: SplitterComponent Identity [Int] -> SplitterComponent Identity [Int] -> Positive Int -> Bool
prop_followedBy1 s1 s2 (Positive n) = splitterOutputs (s1 `followedBy` s2) l
                                      == splitterOutputs (s1 `followedBy` prefix s2) l
   where l = [1 .. n `mod` 300]

prop_followedBy2 :: SplitterComponent Identity [Int] -> Int -> Bool
prop_followedBy2 s n = splitterOutputs (s `followedBy` startOf everything) l == splitterOutputs s l
   where l = [1 .. n `mod` 300]

prop_followedBy3 :: [TestEnum] -> [TestEnum] -> [TestEnum] -> Property
prop_followedBy3 l1 l2 l3 = classify (not (isInfixOf l1 l3)) "trivial" $
                            fst (splitterOutputs (substring l1 `followedBy` substring l2) l3)
                            == sublists (l1 ++ l2) l3

prop_followedBy4 :: [TestEnum] -> [TestEnum] -> [TestEnum] -> Property
prop_followedBy4 l1 l2 l3 = isInfixOf l1 l3
                            ==> classify (not (isInfixOf (l1 ++ l2) l3)) "trivial" $
                                fst (splitterOutputs (substring l1 `followedBy` substring l2) l3) == sublists (l1 ++ l2) l3

prop_followedBy5 :: Positive Int -> NonNegative Int -> Positive Int -> NonNegative Int -> Bool
prop_followedBy5 (Positive i1) (NonNegative i2) (Positive i3) (NonNegative i4) =
   let n1 = i1 `mod` 1000
       n2 = n1 + i2 `mod` 100
       n3 = n2 + i3 `mod` 100
       n4 = n3 + i4 `mod` 100
   in splitterOutputs (substring [n1 .. n2] `followedBy` substring [n2 + 1 .. n3]) [0 .. n4]
         == ([n1 .. n3], [0 .. n1 - 1] ++ [n3 + 1 .. n4])

prop_followedBy6 :: SplitterComponent Identity [Int] -> SplitterComponent Identity [Int] -> Positive Int -> Bool
prop_followedBy6 s1 s2 (Positive n) = sort (fst (splitterOutputs (endOf s1 `followedBy` s2) l)
                                            `union` fst (splitterOutputs (s1 `followedBy` startOf s2) l))
                                      == fst (splitterOutputs (s1 `followedBy` s2) l)
   where l = [1 .. n `mod` 500]

prop_followedByBetween :: Positive Int -> NonNegative Int -> Positive Int -> NonNegative Int -> Bool
prop_followedByBetween (Positive i1) (NonNegative i2) (Positive i3) (NonNegative i4) =
   let n1 = i1 `mod` 500
       n2 = n1 + i2 `mod` 500
       n3 = n2 + i3 `mod` 500 + 1
       n4 = n3 + i4 `mod` 500
   in splitterOutputs
         ((substring [n1] ... substring [n2]) `followedBy` (substring [n2 + 1] ... substring [n3]))
         [0 .. n4]
      == ([n1 .. n3], [0 .. n1 - 1] ++ [n3 + 1 .. n4])

prop_between1 :: SplitterComponent Identity [Int] -> Positive Int -> Bool
prop_between1 splitter (Positive n) =
   splitterOutputs (startOf splitter ... endOf splitter) input == splitterOutputs splitter input
   && splitterOutputs (endOf splitter ... startOf splitter) input == ([], input)
   where input = [1 .. n `mod` 500]

prop_between2 :: SplitterComponent Identity [Int] -> Positive Int -> Bool
prop_between2 splitter (Positive n) = splitterOutputs (startOf everything ... endOf splitter) input
                                      == splitterOutputs (uptoFirst splitter) input
                                      || null (fst $ splitterOutputs splitter input)
   where input = [1 .. n `mod` 500]

prop_XMLtokens1 :: [LowercaseLetter] -> String -> Property
prop_XMLtokens1 name content = name /= [] && intersect content "<&" == []
                               ==> splitterOutputs xmlTokens (fromString $ start ++ content ++ end)
                                   == (fromString $ start ++ end, fromString content)
   where name' = map letterChar name
         start = "<" ++ name' ++ ">"
         end = "</" ++ name' ++ ">"

prop_XMLtokens2 :: [LowercaseLetter] -> [(Identifier, String)] -> String -> Property
prop_XMLtokens2 name attrs content = name /= [] && all validAttribute attrs && intersect content "<&" == []
                                     ==> splitterOutputs xmlTokens (fromString $ start ++ content ++ end)
                                            == (fromString $ start ++ end, fromString content)
   where name' = map letterChar name
         start = "<" ++ name' ++ concatMap attribute attrs ++ ">"
         end = "</" ++ name' ++ ">"

prop_XMLtokens3 :: [LowercaseLetter] -> Bool -> [(Identifier, String)] -> String -> Property
prop_XMLtokens3 name ws attrs content = name /= [] && all validAttribute attrs && intersect content "<&" == []
                                        ==> transducerOutput
                                               (xmlParseTokens >-> select xmlElementContent >-> unparse)
                                               (fromString $ start ++ content ++ end)
                                               == fromString content
   where name' = map letterChar name ++ spaces
         spaces = if ws then "\n\t  " else ""
         start = "<" ++ name' ++ List.intercalate spaces (map attribute attrs) ++ ">"
         end = "</" ++ name' ++ ">"

prop_XMLtokens4 :: NonEmptyList LowercaseLetter -> [(Identifier, String)] -> String -> Bool
prop_XMLtokens4 (NonEmpty name) attrs content =
   transducerOutput (xmlParseTokens >-> unparse) (fromString input) == fromString input
   where name' = map letterChar name
         start = "<" ++ name' ++ concatMap attribute attrs ++ ">"
         end = "</" ++ name' ++ ">"
         content' = concatMap escapeContentCharacter content
         input = start ++ content' ++ end

prop_nestedInXMLcontent :: [Either (Identifier, [(Identifier, String)]) String] -> Bool
prop_nestedInXMLcontent startTagsAndContent = transducerOutput
                                                 (xmlParseTokens
                                                  >-> select (snot xmlElement `nestedIn` xmlElementContent)
                                                  >-> unparse)
                                                 (fromString $ nestXMLelements startTagsAndContent)
                                              == (fromString $
                                                  concatMap escapeContentCharacter $
                                                  concat (rights startTagsAndContent))

prop_whileXMLelement :: [Either (Identifier, [(Identifier, String)]) String] -> Bool
prop_whileXMLelement startTagsAndContent = transducerOutput
                                              (xmlParseTokens
                                               >-> (select xmlElementContent `while` xmlElement)
                                               >-> unparse)
                                              (fromString $ nestXMLelements startTagsAndContent)
                                           == (fromString $
                                               concatMap escapeContentCharacter (concat (rights startTagsAndContent)))

nestXMLelements [] = []
nestXMLelements (Left (Identifier (NonEmpty name), attrs) : rest) = "<" ++ name' ++ concatMap attribute attrs ++ ">"
                                                                    ++ nestXMLelements rest ++ "</" ++ name' ++ ">"
   where name' = map letterChar name
nestXMLelements (Right content : rest) = concatMap escapeContentCharacter content ++ nestXMLelements rest

attribute (Identifier (NonEmpty name), value) =
   " " ++ map letterChar name ++ "=\"" ++ concatMap escapeAttributeCharacter value ++ "\""
validAttribute (Identifier (NonEmpty name), value) = name /= [] && intersect value "<&\"" == []

-- | Escapes a character for inclusion into an XML attribute value.
escapeAttributeCharacter :: Char -> String
escapeAttributeCharacter '"' = "&quot;"
escapeAttributeCharacter '\t' = "&#9;"
escapeAttributeCharacter '\n' = "&#10;"
escapeAttributeCharacter '\r' = "&#13;"
escapeAttributeCharacter x = escapeContentCharacter x

-- | Escapes a character for inclusion into the XML data content.
escapeContentCharacter :: Char -> String
escapeContentCharacter '<' = "&lt;"
escapeContentCharacter '&' = "&amp;"
escapeContentCharacter x = [x]

uppercaseContent :: (Functor f, Monad m) => TransducerComponent m [f String] [f String]
uppercaseContent = atomic "uppercase" 1 (oneToOneTransducer $ map $ fmap (map toUpper))

transducerOutput :: (MonoidNull x, MonoidNull y) => TransducerComponent Identity x y -> x -> y
transducerOutput t = transducerOutput' (with t)

transducerOutput' :: (MonoidNull x, MonoidNull y) => Transducer Identity x y -> x -> y
transducerOutput' t input = case runCoroutine (pipe
                                                   (putAll input)
                                                   (\source-> pipe
                                                                 (\sink-> transduce t source sink)
                                                                 getAll))
                            of Identity (_, (_, output)) -> output

splitterOutputs :: MonoidNull x => SplitterComponent Identity x -> x -> (x, x)
splitterOutputs s input =
   case runCoroutine (pipe
                         (putAll input)
                         (\source->
                           pipe 
                              (\true->
                                pipe
                                   (split (with s) source true)
                                   getAll)
                              getAll))
   of Identity (_, ((_, false), true)) -> (true, false)

splitterUnifiedOutput :: forall x b. SplitterComponent Identity [x] -> [x] -> [(x, Bool)]
splitterUnifiedOutput s input =
   snd $ runIdentity $
   runCoroutine (pipe
                     (\sink-> pipe
                                 (putAll input)
                                 (mapSplit s sink))
                     getAll)
   where mapSplit :: forall a d. AncestorFunctor a d =>
                     SplitterComponent Identity [x] -> Sink Identity a [(x, Bool)] -> Source Identity d [x]
                  -> Coroutine d Identity ()
         mapSplit s sink source = let sink' = liftSink sink :: Sink Identity d [(x, Bool)]
                                  in split (with s) source
                                     (mapSink (\x-> (x, True)) sink')
                                        (mapSink (\x-> (x, False)) sink')

splitterOutputChunks :: SplitterComponent Identity [x] -> [x] -> [([x], Bool)]
splitterOutputChunks s input = 
   transducerOutput (foreach s
                        (group >-> atomic "true" 1 (oneToOneTransducer (\[chunk]-> [(chunk, True)])))
                        (group >-> atomic "false" 1 (oneToOneTransducer (\[chunk]-> [(chunk, False)]))))
                    input

splitterRawChunks :: SplitterComponent Identity [x] -> [[x]] -> [Maybe ([x], Bool)]
splitterRawChunks s input =
   snd $ runIdentity $ runCoroutine $
   pipe
      (\sink-> pipe
         (\sink-> mapM_ (putChunk sink) input)
         (\source-> pipe
                       (\true-> pipe
                                   (split (with s) source true)
                                   (\source-> mapStreamChunks (\chunk-> [Just (chunk, False)]) source sink))
                       (\source-> mapStreamChunks (\chunk-> [Just (chunk, True)]) source sink)))
      getAll

simplestSplitterFromTrace :: SimplestSplitterTrace -> SplitterComponent Identity [x]
simplestSplitterFromTrace (init, last) = splitterFromTrace (map (Just . Just) init, last)

simpleSplitterFromTrace :: SimpleSplitterTrace -> SplitterComponent Identity [x]
simpleSplitterFromTrace (init, last) = splitterFromTrace (map Just init, last)

splitterFromTrace :: SplitterTrace -> SplitterComponent Identity [x]
splitterFromTrace trace = atomic "splitterFromTrace" 1 (splitterFromTrace' trace)

splitterFromTrace' :: forall x. SplitterTrace -> Splitter Identity [x]
splitterFromTrace' trace1 = isolateSplitter s
   where s :: forall d. Functor d => Source Identity d [x] -> Sink Identity d [x] -> Sink Identity d [x] -> Coroutine d Identity ()
         s source true false =
            let follow :: Bool -> [Maybe (Maybe Bool)] -> Seq x -> Coroutine d Identity [x]
                follow previous trace2@(head:tail) q = get source >>= maybe fail succeed
                   where succeed x = let q' = q |> x
                                     in case head
                                        of Nothing -> follow previous tail q'
                                           Just Nothing -> when (not previous) (putChunk true [] >> return ())
                                                           >> follow False tail q'
                                           Just (Just True) -> when (not previous) (putChunk true [] >> return ())
                                                               >> putAll (Foldable.toList (Seq.viewl q')) true
                                                               >> follow True tail Seq.empty
                                           Just (Just False) -> putAll (Foldable.toList (Seq.viewl q')) false
                                                                >> follow False tail Seq.empty
                         fail = if find (maybe False isJust) trace2 == Just (Just (Just True))
                                then putAll (Foldable.toList (Seq.viewl q)) true
                                else putAll (Foldable.toList (Seq.viewl q)) false
            in follow False (cycle (fst trace1 ++ [Just (Just $ snd trace1)])) Seq.empty 
               >> return ()

swap :: (x, y) -> (y, x)
swap (x, y) = (y, x)

mapWords :: (String -> String) -> String -> String
mapWords f s = concat (map (\w@(c:_)-> if isSpace c then w else f w) (groupBy (\x y-> isSpace x == isSpace y) s))

type SimplestSplitterTrace = ([Bool], Bool)
type SimpleSplitterTrace = ([Maybe Bool], Bool)
type SplitterTrace = ([Maybe (Maybe Bool)], Bool)

data TestEnum = One | Two | Three | Four | Five deriving (Enum, Eq, Show)

newtype Identifier = Identifier (NonEmptyList LowercaseLetter) deriving (Eq, Show)

newtype LowercaseLetter = LowercaseLetter{letterChar:: Char} deriving (Eq, Show)

instance Arbitrary TestEnum where
   arbitrary = oneof (map return [One, Two, Three, Four, Five])
instance CoArbitrary TestEnum where
   coarbitrary enum = variant (case enum of {One -> 0; Two -> 1; Three -> 2; Four -> 3; Five -> 4})

-- instance Arbitrary Char where
--     arbitrary     = choose ('\32', '\128')
--     coarbitrary c = variant ((ord c - 32) `rem` 128)

instance Arbitrary Identifier where
    arbitrary     = sized (\size-> fmap Identifier $ resize (size `mod` 50) arbitrary)

instance Arbitrary LowercaseLetter where
    arbitrary     = fmap LowercaseLetter (choose ('a', 'z'))
instance CoArbitrary LowercaseLetter where
    coarbitrary (LowercaseLetter c) = variant ((ord c - 65) `rem` 26)

instance Arbitrary c => Arbitrary (Component c) where
   arbitrary = fmap (atomic "Arbitrary" 1) arbitrary
instance CoArbitrary c => CoArbitrary (Component c) where
   coarbitrary c = coarbitrary (with c)

instance Arbitrary (Splitter Identity [Int]) where
   arbitrary = fmap splitterFromTrace' arbitrary
instance CoArbitrary (Splitter Identity [Int]) where
   coarbitrary s gen = sized (\n-> coarbitrary (transducerOutput' (Combinator.ifs sequentialBinder s
                                                                   (oneToOneTransducer $ const [True])
                                                                   (oneToOneTransducer $ const [False]))
                                                [1..n]) gen)
