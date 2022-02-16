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

-- | Module "Primitives" defines primitive components of 'Producer', 'Consumer', 'Transducer' and 'Splitter' types,
-- defined in the "Types" module.

{-# LANGUAGE ScopedTypeVariables, Rank2Types #-}
{-# OPTIONS_HADDOCK hide #-}

module Control.Concurrent.SCC.Primitives (
   -- * I/O components
   -- ** I/O producers
   fromFile, fromHandle, fromStdIn, fromBinaryHandle,
   -- ** I/O consumers
   appendFile, toFile, toHandle, toStdOut, toBinaryHandle,
   -- * Generic components
   produceFrom, 
   -- ** Generic consumers
   suppress, erroneous, consumeInto,
   -- ** Generic transducers
   parse, unparse, parseSubstring, OccurenceTag, count, toString,
   -- *** List stream transducers
   -- | The following laws hold:
   --
   --    * 'group' '>>>' 'concatenate' == 'id'
   --
   --    * 'concatenate' == 'concatSeparate' []
   group, concatenate, concatSeparate,
   -- ** Generic splitters
   everything, nothing, marked, markedContent, markedWith, contentMarkedWith, one, substring,
   -- * Character stream components
   lowercase, uppercase, whitespace, letters, digits, line, nonEmptyLine,
   )
where

import Prelude hiding (appendFile, getLine, length, null, putStr, tail)

import Control.Applicative (Alternative ((<|>)))
import Control.Exception (assert)
import Control.Monad (forM_, unless, when)
import Control.Monad.Trans.Class (lift)
import Data.ByteString (ByteString)
import Data.Char (isAlpha, isDigit, isSpace, toLower, toUpper)
import Data.List (delete)
import Data.Monoid (Monoid(mappend, mempty), Sum(Sum))
import qualified Data.ByteString as ByteString
import qualified Data.Foldable as Foldable
import System.IO (Handle, IOMode (ReadMode, WriteMode, AppendMode), openFile, hClose, hIsEOF, hClose, isEOF)
import Data.Text (Text, singleton)
import Data.Text.IO (getLine, hGetLine, hPutStr, putStr)

import Data.Monoid.Null (MonoidNull(null))
import Data.Monoid.Cancellative (LeftReductiveMonoid, stripPrefix)
import Data.Monoid.Factorial (FactorialMonoid(splitPrimePrefix), length)
import Text.ParserCombinators.Incremental (string, takeWhile, (<<|>))

import Control.Concurrent.SCC.Streams
import Control.Concurrent.SCC.Types

import Debug.Trace (trace)

-- | Collects the entire input source into the return value.
consumeInto :: forall m x. (Monad m, Monoid x) => Consumer m x x
consumeInto = Consumer getAll

-- | Produces the contents of the given argument.
produceFrom :: forall m x. (Monad m, MonoidNull x) => x -> Producer m x ()
produceFrom l = Producer ((>> return ()) . putAll l)

-- | Consumer 'toStdOut' copies the given source into the standard output.
toStdOut :: Consumer IO Text ()
toStdOut = Consumer (mapMStreamChunks_ (lift . putStr))

-- | Producer 'fromStdIn' feeds the given sink from the standard input.
fromStdIn :: Producer IO Text ()
fromStdIn = Producer (unmapMStreamChunks_ (lift $
                                           isEOF >>= cond (return mempty) (fmap (`mappend` singleton '\n') getLine)))

-- | Reads the named file and feeds the given sink from its contents.
fromFile :: String -> Producer IO Text ()
fromFile path = Producer $ \sink-> do handle <- lift (openFile path ReadMode)
                                      produce (fromHandle handle) sink
                                      lift (hClose handle)

-- | Feeds the given sink from the open text file /handle/.
fromHandle :: Handle -> Producer IO Text ()
fromHandle handle = Producer (unmapMStreamChunks_
                                 (lift $
                                  hIsEOF handle
                                  >>= cond (return mempty) (fmap (`mappend` singleton '\n') $ hGetLine handle)))

-- | Feeds the given sink from the open binary file /handle/. The argument /chunkSize/ determines the size of the chunks
-- read from the handle.
fromBinaryHandle :: Handle -> Int -> Producer IO ByteString ()
fromBinaryHandle handle chunkSize = Producer p
   where p sink = lift (ByteString.hGet handle chunkSize) 
                  >>= \chunk-> unless (ByteString.null chunk) 
                                      (putChunk sink chunk 
                                       >>= \c-> when (ByteString.null c) (p sink))

-- | Creates the named text file and writes the entire given source to it.
toFile :: String -> Consumer IO Text ()
toFile path = Consumer $ \source-> do handle <- lift (openFile path WriteMode)
                                      consume (toHandle handle) source
                                      lift (hClose handle)

-- | Appends the given source to the named text file.
appendFile :: String -> Consumer IO Text ()
appendFile path = Consumer $ \source-> do handle <- lift (openFile path AppendMode)
                                          consume (toHandle handle) source
                                          lift (hClose handle)

-- | Copies the given source into the open text file /handle/.
toHandle :: Handle -> Consumer IO Text ()
toHandle handle = Consumer (mapMStreamChunks_ (lift . hPutStr handle))

-- | Copies the given source into the open binary file /handle/.
toBinaryHandle :: Handle -> Consumer IO ByteString ()
toBinaryHandle handle = Consumer (mapMStreamChunks_ (lift . ByteString.hPut handle))

-- | Transducer 'unparse' removes all markup from its input and passes the content through.
unparse :: forall m x b. (Monad m, Monoid x) => Transducer m [Markup b x] x
unparse = statelessTransducer removeTag
   where removeTag (Content x) = x
         removeTag _ = mempty

-- | Transducer 'parse' prepares input content for subsequent parsing.
parse :: forall m x y. (Monad m, Monoid x) => Parser m x y
parse = statelessChunkTransducer ((: []) . Content)

-- | The 'suppress' consumer suppresses all input it receives. It is equivalent to 'substitute' []
suppress :: forall m x. Monad m => Consumer m x ()
suppress = Consumer (\(src :: Source m a x)-> pour_ src (nullSink :: Sink m a x))

-- | The 'erroneous' consumer reports an error if any input reaches it.
erroneous :: forall m x. (Monad m, MonoidNull x) => String -> Consumer m x ()
erroneous message = Consumer (mapMStreamChunks_ (\x-> unless (null x) (error message)))

-- | The 'lowercase' transforms all uppercase letters in the input to lowercase, leaving the rest unchanged.
lowercase :: forall m. Monad m => Transducer m String String
lowercase = statelessChunkTransducer (map toLower)

-- | The 'uppercase' transforms all lowercase letters in the input to uppercase, leaving the rest unchanged.
uppercase :: forall m. Monad m => Transducer m String String
uppercase = statelessChunkTransducer (map toUpper)

-- | The 'count' transducer counts all its input values and outputs the final tally.
count :: forall m x. (Monad m, FactorialMonoid x) => Transducer m x [Integer]
count = Transducer (\source sink-> foldStream (\n _-> succ n) 0 source >>= put sink)

-- | Converts each input value @x@ to @show x@.
toString :: forall m x. (Monad m, Show x) => Transducer m [x] [String]
toString = oneToOneTransducer (map show)

-- | Transducer 'group' collects all its input into a single list item.
group :: forall m x. (Monad m, Monoid x) => Transducer m x [x]
group = Transducer (\source sink-> getAll source >>= put sink)

-- | Transducer 'concatenate' flattens the input stream of lists of values into the output stream of values.
concatenate :: forall m x. (Monad m, Monoid x) => Transducer m [x] x
concatenate = statelessTransducer id

-- | Same as 'concatenate' except it inserts the given separator list between every two input lists.
concatSeparate :: forall m x. (Monad m, MonoidNull x) => x -> Transducer m [x] x
concatSeparate separator = statefulTransducer (\seen chunk-> (True, if seen then mappend separator chunk else chunk))
                                              False

-- | Splitter 'whitespace' feeds all white-space characters into its /true/ sink, all others into /false/.
whitespace :: forall m. Monad m => Splitter m String
whitespace = statelessSplitter isSpace

-- | Splitter 'letters' feeds all alphabetical characters into its /true/ sink, all other characters into
-- | /false/.
letters :: forall m. Monad m => Splitter m String
letters = statelessSplitter isAlpha

-- | Splitter 'digits' feeds all digits into its /true/ sink, all other characters into /false/.
digits :: forall m. Monad m => Splitter m String
digits = statelessSplitter isDigit

-- | Splitter 'nonEmptyLine' feeds line-ends into its /false/ sink, and all other characters into /true/.
nonEmptyLine :: forall m. Monad m => Splitter m String
nonEmptyLine = statelessSplitter (\ch-> ch /= '\n' && ch /= '\r')

-- | The sectioning splitter 'line' feeds line-ends into its /false/ sink, and line contents into /true/. A single
-- line-end can be formed by any of the character sequences \"\\n\", \"\\r\", \"\\r\\n\", or \"\\n\\r\".
line :: forall m. Monad m => Splitter m String
line = Splitter $ \source true false->
       let loop = peek source >>= maybe (return ()) (( >> loop) . splitLine)
           lineChar c = c /= '\r' && c /= '\n'
           lineEndParser = string "\r\n" <<|> string "\n\r" <<|> string "\r" <<|> string "\n"
           splitLine c = if lineChar c then pourWhile (lineChar . head) source true else putChunk true mempty
                         >> pourParsed lineEndParser source false
       in loop

-- | Splitter 'everything' feeds its entire input into its /true/ sink.
everything :: forall m x. Monad m => Splitter m x
everything = Splitter (\source true _false-> pour source true >>= flip unless (putChunk true mempty >> return ()))

-- | Splitter 'nothing' feeds its entire input into its /false/ sink.
nothing :: forall m x. (Monad m, Monoid x) => Splitter m x
nothing = Splitter (\source _true false-> pour_ source false)

-- | Splitter 'one' feeds all input values to its /true/ sink, treating every value as a separate section.
one :: forall m x. (Monad m, FactorialMonoid x) => Splitter m x
one = Splitter (\source true false-> getWith source $
                                     \x-> putChunk true x
                                          >> mapMStream_ (\x-> putChunk false mempty >> putChunk true x) source)

-- | Splitter 'marked' passes all marked-up input sections to its /true/ sink, and all unmarked input to its
-- /false/ sink.
marked :: forall m x y. (Monad m, Eq y) => Splitter m [Markup y x]
marked = markedWith (const True)

-- | Splitter 'markedContent' passes the content of all marked-up input sections to its /true/ sink, takeWhile the
-- outermost tags and all unmarked input go to its /false/ sink.
markedContent :: forall m x y. (Monad m, Eq y) => Splitter m [Markup y x]
markedContent = contentMarkedWith (const True)

-- | Splitter 'markedWith' passes input sections marked-up with the appropriate tag to its /true/ sink, and the
-- rest of the input to its /false/ sink. The argument /select/ determines if the tag is appropriate.
markedWith :: forall m x y. (Monad m, Eq y) => (y -> Bool) -> Splitter m [Markup y x]
markedWith select = statefulSplitter transition ([], False)
   where transition s@([], _)     Content{} = (s, False)
         transition s@(_, truth)  Content{} = (s, truth)
         transition s@([], _)     (Markup (Point y)) = (s, select y)
         transition s@(_, truth)  (Markup (Point _)) = (s, truth)
         transition ([], _)       (Markup (Start y)) = (([y], select y), select y)
         transition (open, truth) (Markup (Start y)) = ((y:open, truth), truth)
         transition (open, truth) (Markup (End y))   = assert (elem y open) ((delete y open, truth), truth)

-- | Splitter 'contentMarkedWith' passes the content of input sections marked-up with the appropriate tag to
-- its /true/ sink, and the rest of the input to its /false/ sink. The argument /select/ determines if the tag is
-- appropriate.
contentMarkedWith :: forall m x y. (Monad m, Eq y) => (y -> Bool) -> Splitter m [Markup y x]
contentMarkedWith select = statefulSplitter transition ([], False)
   where transition s@(_, truth)  Content{} = (s, truth)
         transition s@(_, truth)  (Markup Point{}) = (s, truth)
         transition ([], _)       (Markup (Start y)) = (([y], select y), False)
         transition (open, truth) (Markup (Start y)) = ((y:open, truth), truth)
         transition (open, truth) (Markup (End y))   = assert (elem y open) (let open' = delete y open
                                                                                 truth' = not (null open') && truth
                                                                             in ((open', truth'), truth'))

-- | Used by 'parseSubstring' to distinguish between overlapping substrings.
data OccurenceTag = Occurence Int deriving (Eq, Show)

instance Enum OccurenceTag where
   succ (Occurence n) = Occurence (succ n)
   pred (Occurence n) = Occurence (pred n)
   toEnum = Occurence
   fromEnum (Occurence n) = n

-- | Performs the same task as the 'substring' splitter, but instead of splitting it outputs the input as @'Markup' x
-- 'OccurenceTag'@ in order to distinguish overlapping strings.
parseSubstring :: forall m x. (Monad m, Eq x, LeftReductiveMonoid x, FactorialMonoid x) => x -> Parser m x OccurenceTag
parseSubstring s = 
   case splitPrimePrefix s
   of Nothing -> Transducer $ 
                 \ source sink -> put sink marker >> mapStream (\x-> [Content x, marker]) source sink
         where marker = Markup (Point (toEnum 1))
      Just (first, rest)->
         isolateTransducer $ \ source sink ->
         pipe (\sink'->
                let findFirst = pourWhile (/= first) source sink'
                                >> test
                    test = getParsed (string s) source
                           >>= \t-> if null t
                                    then getWith source (\x-> put sink (Content x) >> findFirst)
                                    else put sink (Markup (Start (toEnum 0)))
                                         >> put sink prefixContent
                                         >> if null shared then put sink (Markup (End (toEnum 0))) >> findFirst
                                            else testOverlap 0
                    testOverlap n = getParsed (string postfix) source
                                    >>= \t-> if null t
                                             then forM_ [n - maxOverlaps + 1 .. n]
                                                        (\i-> put sink sharedContent
                                                              >> put sink (Markup (End (toEnum i))))
                                                      >> findFirst
                                             else let n' = succ n
                                                  in put sink (Markup (Start (toEnum n')))
                                                     >> put sink prefixContent
                                                     >> when (n' >= maxOverlaps)
                                                             (put sink (Markup (End (toEnum (n' - maxOverlaps)))))
                                                     >> testOverlap n'
                    (prefix, shared, postfix) = overlap s s
                    maxOverlaps = (length s - 1) `div` length prefix
                    prefixContent = Content prefix
                    sharedContent = Content shared
                in findFirst)
              (\src-> mapStreamChunks ((: []) . Content) src sink)
         >> return ()

-- | Splitter 'substring' feeds to its /true/ sink all input parts that match the contents of the given list
-- argument. If two overlapping parts of the input both match the argument, both are sent to /true/ and each is preceded
-- by an empty chunk on /false/.
substring :: forall m x. (Monad m, Eq x, LeftReductiveMonoid x, FactorialMonoid x) => x -> Splitter m x
substring s = 
   Splitter $ \ source true false ->
   case splitPrimePrefix s
   of Nothing -> putChunk true mempty
                 >> mapMStream_ (\x-> putChunk false x >> putChunk true mempty) source
      Just (first, rest) ->
         let findFirst = pourWhile (/= first) source false
                         >> test
             test = getParsed (string s) source
                    >>= \t-> if null t
                             then getWith source (\x-> putChunk false x >> findFirst)
                             else putChunk false mempty
                                  >> putAll prefix true
                                  >> if null shared then findFirst else testOverlap
             testOverlap = getParsed (string postfix) source
                           >>= \t-> if null t
                                    then putAll shared true >> findFirst
                                    else putChunk false mempty
                                         >> putAll prefix true
                                         >> testOverlap
             (prefix, shared, postfix) = overlap s s
         in findFirst

overlap :: (LeftReductiveMonoid x, FactorialMonoid x) => x -> x -> (x, x, x)
overlap e s | null e = (e, e, s)
overlap s1 s2 = case splitPrimePrefix s1
                of Nothing -> (s1, s1, s2)
                   Just (head, tail) -> case stripPrefix tail s2
                                        of Just rest -> (head, tail, rest)
                                           Nothing -> let (o1, o2, o3) = overlap tail s2
                                                      in (mappend head o1, o2, o3)

-- | A utility function wrapping if-then-else, useful for handling monadic truth values
cond :: a -> a -> Bool -> a
cond x y test = if test then x else y
