{-
    Copyright 2009-2012 Mario Blazevic

    This file is part of the Streaming Component Combinators (SCC) project.

    The SCC project is free software: you can redistribute it and/or modify it under the terms of the GNU General Public
    License as published by the Free Software Foundation, either version 3 of the License, or (at your moptional) any later
    version.

    SCC is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY; without even the implied warranty
    of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU General Public License for more details.

    You should have received a copy of the GNU General Public License along with SCC.  If not, see
    <http://www.gnu.org/licenses/>.
-}

-- | Module "XML" defines primitives and combinators for parsing and manipulating XML.

{-# LANGUAGE PatternGuards, FlexibleContexts, MultiParamTypeClasses, OverloadedStrings,
             ScopedTypeVariables, Rank2Types #-}
{-# OPTIONS_HADDOCK hide #-}

module Control.Concurrent.SCC.XML (
   -- * Parsing XML
   xmlTokens, parseXMLTokens, expandXMLEntity, XMLToken(..),
   -- * XML splitters
   xmlElement, xmlElementContent, xmlElementName, xmlAttribute, xmlAttributeName, xmlAttributeValue,
   xmlElementHavingTagWith
   )
where

import Prelude hiding (takeWhile)

import Control.Applicative (Alternative ((<|>)))
import Control.Arrow ((>>>))
import Control.Monad (when)
import Data.Char
import Data.Maybe (mapMaybe)
import Data.Monoid (Monoid(..))
import Data.List (find)
import Data.String (IsString(fromString))
import Data.Text (Text, pack, unpack, singleton)
import qualified Data.Text as Text
import Numeric (readDec, readHex)

import Text.ParserCombinators.Incremental (Parser, more, feed, anyToken, satisfy, concatMany, takeWhile, takeWhile1, 
                                           string, moptional, skip, lookAhead, notFollowedBy, mapIncremental, (><))
import qualified Text.ParserCombinators.Incremental.LeftBiasedLocal as LeftBiasedLocal (Parser)
import Text.ParserCombinators.Incremental.LeftBiasedLocal (leftmost)
import Control.Monad.Coroutine (Coroutine, sequentialBinder)

import Control.Concurrent.SCC.Streams
import Control.Concurrent.SCC.Types hiding (Parser)
import Control.Concurrent.SCC.Coercions (coerce)
import Control.Concurrent.SCC.Combinators (parserToSplitter, findsTrueIn)

data XMLToken = StartTag | EndTag | EmptyTag
              | ElementName | AttributeName | AttributeValue
              | EntityReference | EntityName
              | ProcessingInstruction | ProcessingInstructionText
              | Comment | CommentText
              | StartMarkedSectionCDATA | EndMarkedSection | DoctypeDeclaration
              | ErrorToken String
                deriving (Eq, Show)

-- | Converts an XML entity name into the text value it represents: @expandXMLEntity \"lt\" = \"<\"@.
expandXMLEntity :: String -> String
expandXMLEntity "lt" = "<"
expandXMLEntity "gt" = ">"
expandXMLEntity "quot" = "\""
expandXMLEntity "apos" = "'"
expandXMLEntity "amp" = "&"
expandXMLEntity ('#' : 'x' : codePoint) = [chr (fst $ head $ readHex codePoint)]
expandXMLEntity ('#' : codePoint) = [chr (fst $ head $ readDec codePoint)]
expandXMLEntity e = error ("String \"" ++ e ++ "\" is not a built-in entity name.")

newtype XMLStream = XMLStream {chunk :: [Markup XMLToken Text]} deriving (Show)

instance Semigroup XMLStream where
   l <> XMLStream [] = l
   XMLStream [] <> r = r
   XMLStream l <> XMLStream r@((Content rc):rt) =
      case last l
      of Content lc -> XMLStream (init l ++ Content (lc <> rc) : rt)
         _ -> XMLStream (l ++ r)
   XMLStream l <> XMLStream r = XMLStream (l ++ r)

instance Monoid XMLStream where
   mempty = XMLStream []
   mappend = (<>)

xmlParser :: LeftBiasedLocal.Parser Text XMLStream
xmlParser = concatMany (xmlContent <|> xmlMarkup)
   where xmlContent = mapContent $ takeWhile1 (\x-> x /= "<" && x /= "&")
         xmlMarkup = (string "<" >> ((startTag <|> endTag <|> processingInstruction <|> declaration)
                                     <|> return (XMLStream [Markup $ Point errorUnescapedContentLT,
                                                             Content (singleton '<')])))
                     <|>
                     entityReference "&"
         startTag = return (XMLStream [Markup (Start StartTag), Content (singleton '<'), Markup (Start ElementName)])
                    >< name
                    >< return (XMLStream [Markup (End ElementName)])
                    >< whiteSpace
                    >< attributes
                    >< moptional (string "/" >> return (XMLStream [Markup (Point EmptyTag), Content (singleton '/')]))
                    >< whiteSpace
                    >< (string ">" >> return (XMLStream [Content (singleton '>'), Markup (End StartTag)])
                        <|> return (XMLStream [Markup $ Point unterminatedStartTag, Markup $ End StartTag]))
         entityReference s = string s
                             >> (return (XMLStream [Markup (Start EntityReference), Content s,
                                                    Markup (Start EntityName)])
                                 >< name
                                 >< (string ";" >> return (XMLStream [Markup (End EntityName), Content (singleton ';'),
                                                                      Markup (End EntityReference)]))
                                 <|> return (XMLStream [Markup $ Point $ errorBadEntityReference, Content s]))
         attributes = concatMany (attribute >< whiteSpace)
         attribute = return (XMLStream [Markup (Start AttributeName)])
                     >< name
                     >< return (XMLStream [Markup (End AttributeName)])
                     >< (mapContent (string "=")
                         <|> (fmap (\x-> XMLStream [Markup $ Point $ errorBadAttribute x]) anyToken
                               >< whiteSpace >< moptional (mapContent $ string "=")))
                     >< ((string "\"" <|> string "\'")
                         >>= \quote-> return (XMLStream [Content quote, Markup (Start AttributeValue)])
                                      >< mapContent (takeWhile (/= quote))
                                      >< return (XMLStream [Markup (End AttributeValue), Content quote])
                                      >< skip (string quote)
                         <|> (anyToken >>= \q-> return (XMLStream [Markup $ Point $ errorBadQuoteCharacter q,
                                                                    Content quote])))
         endTag = (string "/" >> return (XMLStream [Markup (Start EndTag), Content "</", Markup (Start ElementName)]))
                  >< name
                  >< return (XMLStream [Markup (End ElementName)])
                  >< whiteSpace
                  >< (string ">" >> return (XMLStream [Content (singleton '>'), Markup (End EndTag)])
                      <|> return (XMLStream [Markup $ Point unterminatedEndTag, Markup (End EndTag)]))
         processingInstruction = (string "?"
                                  >> return (XMLStream [Markup (Start ProcessingInstruction), Content "<?",
                                                        Markup (Start ProcessingInstructionText)]))
                                 >< upto "?>"
                                 >< (string "?>"
                                     >> return (XMLStream [Markup (End ProcessingInstructionText), Content "?>",
                                                           Markup (End ProcessingInstruction)])
                                     <|> return (XMLStream [Markup $ Point unterminatedProcessingInstruction]))
         declaration = string "!"
                       >> ((comment <|> cdataMarkedSection <|> doctypeDeclaration)
                           <|> return (XMLStream [Markup $ Point $ errorBadDeclarationType, Content "<"]))
         comment = (string "--" >> return (XMLStream [Markup (Start Comment), Content "<!--",
                                                       Markup (Start CommentText)]))
                   >< upto "-->"
                   >< (string "-->" >> return (XMLStream [Markup (End CommentText), Content "-->",
                                                          Markup (End Comment)])
                       <|> return (XMLStream [Markup $ Point unterminatedComment]))
         cdataMarkedSection = (string "[CDATA["
                               >> return (XMLStream [Markup (Start StartMarkedSectionCDATA), Content "<![CDATA[",
                                                     Markup (End StartMarkedSectionCDATA)]))
                              >< upto "]]>"
                              >< (string "]]>"
                                  >> return (XMLStream [Markup (Start EndMarkedSection), Content "]]>",
                                                        Markup (End EndMarkedSection)])
                                  <|> return (XMLStream [Markup $ Point unterminatedMarkedSection]))
         doctypeDeclaration = (string "DOCTYPE" >> return (XMLStream [Markup (Start DoctypeDeclaration),
                                                                       Content "<!DOCTYPE"]))
                              >< whiteSpace
                              >< (name
                                  >< whiteSpace
                                  >< moptional ((mapContent (string "SYSTEM")
                                              <|> mapContent (string "PUBLIC") >< whiteSpace >< literal)
                                             >< whiteSpace >< literal >< whiteSpace)
                                  >< moptional (mapContent (string "[") >< whiteSpace
                                             >< concatMany ((markupDeclaration <|> comment <|> processingInstruction
                                                        <|> entityReference "%")
                                                       >< whiteSpace)
                                             >< mapContent (string "]") >< whiteSpace)
                                  >< mapContent (string ">")
                                  <|> return (XMLStream [Markup (Point errorMalformedDoctypeDeclaration)]))
                              >< return (XMLStream [Markup (End DoctypeDeclaration)])
         literal = (string "\"" <|> string "\'")
                   >>= \quote-> return (XMLStream [Content quote])
                                >< mapContent (takeWhile (/= quote))
                                >< return (XMLStream [Content quote])
                                >< skip (string quote)
         markupDeclaration= mapContent (string "<!")
                            >< (concatMany (mapContent (takeWhile1 (\x-> x /= ">" && x /= "\"" && x /= "\'")) <|> literal)
                                >< mapContent (string ">")
                                <|> return (XMLStream [Markup $ Point unterminatedMarkupDeclaration]))
         name = mapContent (takeWhile1 (isNameChar . Text.head))
         mapContent = mapIncremental (XMLStream . (:[]) . Content)
         whiteSpace = mapContent (takeWhile (isSpace . Text.head))
         upto end@(lead:_) = mapContent (concatMany (takeWhile1 ((lead /=) . Text.head)
                                                     <|> notFollowedBy (string $ fromString end) >< anyToken))

errorBadQuoteCharacter q = ErrorToken ("Invalid quote character " ++ show q)
errorBadAttribute x = ErrorToken ("Invalid character " ++ show x ++ " following attribute name")
errorBadEntityReference = ErrorToken "Invalid entity reference."
errorBadDeclarationType = ErrorToken "The \"<!\" sequence must be followed by \"[CDATA[\" or \"--\"."
errorMalformedDoctypeDeclaration = ErrorToken "Malformed DOCTYPE declaration."
errorUnescapedContentLT = ErrorToken "Unescaped character '<' in content"
unterminatedComment = ErrorToken "Unterminated comment."
unterminatedMarkedSection = ErrorToken "Unterminated marked section."
unterminatedMarkupDeclaration = ErrorToken "Unterminated markup declaration."
unterminatedStartTag = ErrorToken "Missing '>' at the end of start tag."
unterminatedEndTag = ErrorToken "Missing '>' at the end of end tag."
unterminatedProcessingInstruction = ErrorToken "Unterminated processing instruction."

isNameStart x = isLetter x || x == '_'

isNameChar x = isAlphaNum x || x == '_' || x == '-' || x == ':'

-- | XML markup splitter wrapping 'parseXMLTokens'.
xmlTokens :: Monad m => Splitter m Text
xmlTokens = parserToSplitter parseXMLTokens

-- | The XML token parser. This parser converts plain text to parsed text, which is a precondition for using the
-- remaining XML components.
parseXMLTokens :: Monad m => Transducer m Text [Markup XMLToken Text]
parseXMLTokens = Transducer (pourParsed (mapIncremental chunk xmlParser))

dispatchOnString :: forall m a d r. (Monad m, AncestorFunctor a d) =>
                    Source m a [Char] -> (String -> Coroutine d m r) -> [(String, String -> Coroutine d m r)]
                 -> Coroutine d m r
dispatchOnString source failure fullCases = dispatch fullCases id
   where dispatch cases consumed
            = case find (null . fst) cases
              of Just (~"", rhs) -> rhs (consumed "")
                 Nothing -> get source
                            >>= maybe
                                   (failure (consumed ""))
                                   (\x-> case mapMaybe (startingWith x) cases
                                         of [] -> failure (consumed [x])
                                            subcases -> dispatch (subcases ++ fullCases) (consumed . (x :)))
         startingWith x ~(y:rest, rhs) | x == y = Just (rest, rhs)
                                       | otherwise = Nothing

getElementName :: forall m a d. (Monad m, AncestorFunctor a d) =>
                  Source m a [Markup XMLToken Text] -> ([Markup XMLToken Text] -> [Markup XMLToken Text])
               -> Coroutine d m ([Markup XMLToken Text], Maybe Text)
getElementName source f = get source
                          >>= maybe
                                 (return (f [], Nothing))
                                 (\x-> let f' = f . (x:)
                                       in case x
                                          of Markup (Start ElementName) -> getRestOfRegion ElementName source f' id
                                             Markup (Point ErrorToken{}) -> getElementName source f'
                                             Content{} -> getElementName source f'
                                             _ -> error ("Expected an ElementName, received " ++ show x))

getRestOfRegion :: forall m a d. (Monad m, AncestorFunctor a d) =>
                   XMLToken -> Source m a [Markup XMLToken Text]
                -> ([Markup XMLToken Text] -> [Markup XMLToken Text]) -> (Text -> Text)
                -> Coroutine d m ([Markup XMLToken Text], Maybe Text)
getRestOfRegion token source f g = getWhile isContent source
                                   >>= \content-> get source
                                   >>= \x-> case x
                                            of Just y@(Markup End{})
                                                  -> return (f (content ++ [y]),
                                                             Just (g $ Text.concat $ map fromContent content))
                                               _ -> error ("Expected rest of " ++ show token ++ ", received " ++ show x)

pourRestOfRegion :: forall m a1 a2 a3 d. (Monad m, AncestorFunctor a1 d, AncestorFunctor a2 d, AncestorFunctor a3 d) =>
                    XMLToken -> Source m a1 [Markup XMLToken Text]
                           -> Sink m a2 [Markup XMLToken Text] -> Sink m a3 [Markup XMLToken Text]
                 -> Coroutine d m Bool
pourRestOfRegion token source sink endSink = pourWhile isContent source sink
                                             >> get source
                                             >>= maybe
                                                    (return False)
                                                    (\x-> case x
                                                          of Markup (End token') | token == token' -> put endSink x
                                                                                                      >> return True
                                                             _ -> error ("Expected rest of " ++ show token
                                                                         ++ ", received " ++ show x))

getRestOfStartTag :: forall m a d. (Monad m, AncestorFunctor a d) =>
                     Source m a [Markup XMLToken Text] -> Coroutine d m ([Markup XMLToken Text], Bool)
getRestOfStartTag source = do rest <- getWhile notEndTag source
                              end <- get source
                              case end of Nothing -> return (rest, False)
                                          Just e@(Markup (End StartTag)) -> return (rest ++ [e], True)
                                          Just e@(Markup (Point EmptyTag)) ->
                                             getRestOfStartTag source
                                             >>= \(rest', _)-> return (rest ++ (e: rest'), False)
                                          _ -> error "getWhile returned early!"
   where notEndTag [Markup (End StartTag)] = False
         notEndTag [Markup (Point EmptyTag)] = False
         notEndTag _ = True

getRestOfEndTag :: forall m a d. (Monad m, AncestorFunctor a d) =>
                   Source m a [Markup XMLToken Text] -> Coroutine d m [Markup XMLToken Text]
getRestOfEndTag source = getWhile (/= [Markup (End EndTag)]) source
                         >>= \tokens-> get source
                                       >>= maybe (error "No end to the end tag!") (return . (tokens ++) . (:[]))

findEndTag :: forall m a1 a2 a3 d. (Monad m, AncestorFunctor a1 d, AncestorFunctor a2 d, AncestorFunctor a3 d) =>
              Source m a1 [Markup XMLToken Text] -> Sink m a2 [Markup XMLToken Text] -> Sink m a3 [Markup XMLToken Text]
              -> Text
              -> Coroutine d m ()
findEndTag source sink endSink name = findTag where
   findTag = pourWhile noTagStart source sink
             >> get source
             >>= maybe (return ()) consumeOne
   noTagStart [Markup (Start StartTag)] = False
   noTagStart [Markup (Start EndTag)] = False
   noTagStart _ = True
   consumeOne x@(Markup (Start EndTag)) = do (tokens, mn) <- getElementName source (x :)
                                             maybe
                                                (return ())
                                                (\name'-> getRestOfEndTag source
                                                          >>= \rest-> if name == name'
                                                                      then putAll (tokens ++ rest) endSink
                                                                           >> return ()
                                                                      else putAll (tokens ++ rest) sink
                                                                           >> findTag)
                                                mn
   consumeOne x@(Markup (Start StartTag)) = do (tokens, mn) <- getElementName source (x :)
                                               maybe
                                                  (return ())
                                                  (\name'-> do (rest, hasContent) <- getRestOfStartTag source
                                                               _ <- putAll (tokens ++ rest) sink
                                                               when hasContent (findEndTag source sink sink name')
                                                               findTag)
                                                  mn
   consumeOne _ = error "pourWhile returned early!"

findStartTag :: forall m a1 a2 d. (Monad m, AncestorFunctor a1 d, AncestorFunctor a2 d) =>
                Source m a1 [Markup XMLToken Text] -> Sink m a2 [Markup XMLToken Text]
             -> Coroutine d m (Maybe (Markup XMLToken Text))
findStartTag source sink = pourWhile (/= [Markup (Start StartTag)]) source sink >> get source

-- | Splits all top-level elements with all their content to /true/, all other input to /false/.
xmlElement :: Monad m => Splitter m [Markup XMLToken Text]
xmlElement = Splitter $
             \source true false->
             let split0 = findStartTag source false
                          >>= maybe (return [])
                                 (\x-> do putChunk false mempty
                                          put true x
                                          (tokens, mn) <- getElementName source id
                                          maybe
                                             (putAll tokens true)
                                             (\name-> do (rest, hasContent) <- getRestOfStartTag source
                                                         _ <- putAll (tokens ++ rest) true
                                                         if hasContent
                                                            then split1 name
                                                            else split0)
                                                mn)
                 split1 name = findEndTag source true true name
                               >> split0
             in split0 >> return ()

-- | Splits the content of all top-level elements to /true/, their tags and intervening input to /false/.
xmlElementContent :: Monad m => Splitter m [Markup XMLToken Text]
xmlElementContent = Splitter $
                    \source true false->
                    let split0 = findStartTag source false
                                 >>= maybe (return [])
                                        (\x-> do put false x
                                                 (tokens, mn) <- getElementName source id
                                                 maybe
                                                    (putAll tokens false)
                                                    (\name-> do (rest, hasContent) <- getRestOfStartTag source
                                                                _ <- putAll (tokens ++ rest) false
                                                                if hasContent
                                                                   then split1 name
                                                                   else split0)
                                                    mn)
                        split1 name = findEndTag source true false name
                                      >> split0
                    in split0 >> return ()

-- | Similiar to @('Control.Concurrent.SCC.Combinators.having' 'element')@, except it runs the argument splitter
-- only on each element's start tag, not on the entire element with its content.
xmlElementHavingTagWith :: forall m b. Monad m => Splitter m [Markup XMLToken Text] -> Splitter m [Markup XMLToken Text]
xmlElementHavingTagWith test =
      isolateSplitter $ \ source true false ->
         let split0 = findStartTag source false
                      >>= maybe (return ())
                             (\x-> do (tokens, mn) <- getElementName source (x :)
                                      maybe
                                         (return ())
                                         (\name-> do (rest, hasContent) <- getRestOfStartTag source
                                                     let tag = tokens ++ rest
                                                     (_, found) <- pipe (putAll tag) (findsTrueIn test)
                                                     if found then putChunk false mempty
                                                                   >> putAll tag true
                                                                   >> split1 hasContent true name
                                                        else putAll tag false
                                                             >> split1 hasContent false name)
                                         mn)
             split1 hasContent sink name = when hasContent (findEndTag source sink sink name)
                                           >> split0
      in split0

-- | Splits every attribute specification to /true/, everything else to /false/.
xmlAttribute :: Monad m => Splitter m [Markup XMLToken Text]
xmlAttribute = Splitter $
               \source true false->
               let split0 = getWith source
                               (\x-> case x
                                     of [Markup (Start AttributeName)] ->
                                           do putChunk false mempty
                                              putChunk true x
                                              pourRestOfRegion AttributeName source true true
                                                 >>= flip when split1
                                        _ -> putChunk false x >> split0)
                   split1 = getWith source
                               (\x-> case x
                                     of [Markup (Start AttributeValue)]
                                           -> putChunk true x
                                              >> pourRestOfRegion AttributeValue source true true
                                              >>= flip when split0
                                        _ -> putChunk true x >> split1)
               in split0

-- | Splits every element name, including the names of nested elements and names in end tags, to /true/, all the rest of
-- input to /false/.
xmlElementName :: Monad m => Splitter m [Markup XMLToken Text]
xmlElementName = Splitter (splitSimpleRegions ElementName)

-- | Splits every attribute name to /true/, all the rest of input to /false/.
xmlAttributeName :: Monad m => Splitter m [Markup XMLToken Text]
xmlAttributeName = Splitter  (splitSimpleRegions AttributeName)

-- | Splits every attribute value, excluding the quote delimiters, to /true/, all the rest of input to /false/.
xmlAttributeValue :: Monad m => Splitter m [Markup XMLToken Text]
xmlAttributeValue = Splitter (splitSimpleRegions AttributeValue)

splitSimpleRegions :: Monad m => XMLToken -> OpenSplitter m a1 a2 a3 d [Markup XMLToken Text] ()
splitSimpleRegions token source true false = split0
   where split0 = getWith source consumeOne
         consumeOne x@[Markup (Start token')] | token == token' = putChunk false x
                                                                  >> putChunk true mempty
                                                                  >> pourRestOfRegion token source true false
                                                                  >>= flip when split0
         consumeOne x = putChunk false x >> split0

isContent :: [Markup b x] -> Bool
isContent [Content{}] = True
isContent _ = False

fromContent :: Markup b x -> x
fromContent (Content x) = x
fromContent _ = error "fromContent expects Content!"
