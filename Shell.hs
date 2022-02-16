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

{-# LANGUAGE ScopedTypeVariables, Rank2Types, GADTs, FlexibleContexts, PatternGuards #-}

module Main where

import Prelude hiding (appendFile, interact, id, last, null, sequence)
import Data.List (intersperse, partition)
import Data.Char (isAlphaNum)
import Data.Maybe (fromJust)
import Data.Monoid (Monoid)
import Data.Text (Text)
import Control.Concurrent (forkIO)
import Control.Exception (evaluate)
import Control.Monad (liftM, when)
import Control.Monad.Trans.Class (lift)
import qualified Text.Parsec as Parsec
import qualified Text.Parsec.String as Parsec
import Text.Parsec hiding (count, parse)
import Text.Parsec.String hiding (Parser)
import Text.Parsec.Language (emptyDef)
import Text.Parsec.Token
import System.Console.GetOpt
import System.Console.Haskeline (InputT, defaultSettings, getInputLine, runInputT)
import System.Environment (getArgs)
import System.IO (BufferMode (NoBuffering), hFlush, hIsWritable, hPutStrLn, hReady, hSetBuffering, stderr, stdout)
import qualified System.Process as Process

import Control.Concurrent.MVar
import Debug.Trace (trace)
import System.IO (Handle, IOMode (ReadMode, WriteMode, AppendMode), openFile, hClose,
                  hGetChar, hGetContents, hPutChar, hFlush, hIsEOF, hClose, putChar, isEOF, stdout)

import Control.Monad.Parallel (MonadParallel)
import Control.Monad.Coroutine
import Data.Monoid.Null (MonoidNull(null))
import Data.Monoid.Factorial (FactorialMonoid)

import Control.Concurrent.Configuration (Component, atomic, showComponentTree, usingThreads, with)
import Control.Concurrent.SCC.Streams
import Control.Concurrent.SCC.Types
import qualified Control.Concurrent.SCC.Coercions as Coercions
import Control.Concurrent.SCC.Configurable hiding ((&&), (||))
import Control.Concurrent.SCC.Combinators (JoinableComponentPair)
import qualified Control.Concurrent.SCC.Configurable as Combinators ((&&), (||))

data Expression where
   -- Compiled expressions
   Compiled         :: TypeTag x -> Component x -> Expression
   -- Generic expressions
   NativeCommand    :: String -> Expression
   TypeError        :: TypeTag x -> TypeTag y -> Expression -> Expression
   Join             :: Expression -> Expression -> Expression
   Sequence         :: Expression -> Expression -> Expression
   Pipe             :: Expression -> Expression -> Expression
   If               :: Expression -> Expression -> Expression -> Expression
   ForEach          :: Expression -> Expression -> Expression -> Expression
   -- Void expressions, i.e. commands
   Exit             :: Expression
   -- ProducerComponent constructs
   ProduceFrom      :: String -> Expression
   FileProducer     :: String -> Expression
   StdInProducer    :: Expression
   -- ConsumerComponent constructs
   FileConsumer     :: String -> Expression
   FileAppend       :: String -> Expression
   Suppress         :: Expression
   ErrorConsumer    :: String -> Expression
   -- TransducerComponent constructs
   Select           :: Expression -> Expression
   While            :: Expression -> Expression -> Expression
   ExecuteTransducer :: Expression
   IdentityTransducer :: Expression
   Count            :: Expression
   Concatenate      :: Expression
   Group            :: Expression
   Unparse          :: Expression
   Uppercase        :: Expression
   ShowTransducer   :: Expression
   -- SplitterComponent constructs
   EverythingSplitter :: Expression
   NothingSplitter  :: Expression
   WhitespaceSplitter :: Expression
   LineSplitter     :: Expression
   LetterSplitter   :: Expression
   DigitSplitter    :: Expression
   MarkedSplitter   :: Expression
   OneSplitter      :: Expression
   SubstringSplitter :: String -> Expression
   And              :: Expression -> Expression -> Expression
   Or               :: Expression -> Expression -> Expression
   ZipWithAnd       :: Expression -> Expression -> Expression
   ZipWithOr        :: Expression -> Expression -> Expression
   Not              :: Expression -> Expression
   FollowedBy       :: Expression -> Expression -> Expression
   Nested           :: Expression -> Expression -> Expression
   Having           :: Expression -> Expression -> Expression
   HavingOnly       :: Expression -> Expression -> Expression
   Between          :: Expression -> Expression -> Expression
   First            :: Expression -> Expression
   Last             :: Expression -> Expression
   Prefix           :: Expression -> Expression
   Suffix           :: Expression -> Expression
   Prepend          :: Expression -> Expression
   Append           :: Expression -> Expression
   Substitute       :: Expression -> Expression
   StartOf          :: Expression -> Expression
   EndOf            :: Expression -> Expression
   -- XML PrimitiveComponents
   XMLTokenParser    :: Expression
   XMLAttribute      :: Expression
   XMLAttributeName  :: Expression
   XMLAttributeValue :: Expression
   XMLElement        :: Expression
   XMLElementContent :: Expression
   XMLElementName    :: Expression
   XMLElementHavingTag  :: Expression -> Expression

instance Show Expression where
   showsPrec _ (Compiled tag c) rest = "compiled " ++ shows tag rest
   showsPrec _ (NativeCommand cmd) rest = "native \"" ++ cmd ++ "\"" ++ rest
   showsPrec p (Pipe left right) rest | p < 3 = showsPrec 3 left (" | " ++ showsPrec 2 right rest)
   showsPrec _ (If s t f) rest
      = "if " ++ showsPrec 0 s (" then " ++ showsPrec 0 t (" else " ++ showsPrec 0 f (" end if" ++ rest)))
   showsPrec _ (ForEach s t f) rest = "foreach " ++ showsPrec 0 s (" then " ++ showsPrec 0 t
                                                                   (" else " ++ showsPrec 0 f (" end foreach" ++ rest)))
   showsPrec _ Exit rest = "Exit" ++ rest
   showsPrec _ (FileProducer f) rest = "FileProducer \"" ++ f ++ "\"" ++ rest
   showsPrec _ (ProduceFrom str) rest = "echo \"" ++ str ++ "\"" ++ rest
   showsPrec 0 (Sequence p1 p2) rest = showsPrec 2 p1 (";\n" ++ showsPrec 0 p2 rest)
   showsPrec 1 (Sequence p1 p2) rest = showsPrec 2 p1 ("; " ++ showsPrec 1 p2 rest)
   showsPrec p e@Sequence{} rest = "(" ++ showsPrec 1 e (')' : rest)
   showsPrec 0 (Join p1 p2) rest = showsPrec 2 p1 (" &\n" ++ showsPrec 0 p2 rest)
   showsPrec 1 (Join p1 p2) rest = showsPrec 2 p1 (" & " ++ showsPrec 1 p2 rest)
   showsPrec p e@Join{} rest = "(" ++ showsPrec 1 e (')' : rest)
   showsPrec _ (FileConsumer f) rest = "> \"" ++ f ++ "\"" ++ rest
   showsPrec _ (FileAppend f) rest = ">> \"" ++ f ++ "\"" ++ rest
   showsPrec _ (Suppress) rest = "suppress" ++ rest
   showsPrec _ (ErrorConsumer e) rest = "error \"" ++ e ++ "\"" ++ rest
   showsPrec p (Select s) rest | p < 4 = "select " ++ showsPrec 4 s rest
   showsPrec _ (While s t) rest = "while " ++ showsPrec 0 s (" do " ++ showsPrec 0 t (" end while" ++ rest))
   showsPrec p (And s1 s2) rest | p < 4 = showsPrec 4 s1 (" >& " ++ showsPrec 4 s2 rest)
   showsPrec p (Or s1 s2) rest | p < 4 = showsPrec 4 s1 (" >| " ++ showsPrec 4 s2 rest)
   showsPrec p (ZipWithAnd s1 s2) rest | p < 4 = showsPrec 4 s1 (" && " ++ showsPrec 4 s2 rest)
   showsPrec p (ZipWithOr s1 s2) rest | p < 4 = showsPrec 4 s1 (" || " ++ showsPrec 4 s2 rest)
   showsPrec p (FollowedBy s1 s2) rest | p < 4 = showsPrec 4 s1 (", " ++ showsPrec 4 s2 rest)
   showsPrec p (Not s) rest | p < 4 = ">! " ++ showsPrec 4 s rest
   showsPrec p (Nested s1 s2) rest | p < 4 = "nested " ++ showsPrec 4 s1 (" in " ++ showsPrec 4 s2 (" end nested" ++ rest))
   showsPrec p (Having s1 s2) rest | p < 4 = showsPrec 4 s1 (" having " ++ showsPrec 4 s2 rest)
   showsPrec p (HavingOnly s1 s2) rest | p < 4 = showsPrec 4 s1 (" having-only " ++ showsPrec 4 s2 rest)
   showsPrec p (Between s1 s2) rest | p < 4 = showsPrec 4 s1 (" ... " ++ showsPrec 4 s2 rest)
   showsPrec p (First s) rest | p < 4 = "first " ++ showsPrec 4 s rest
   showsPrec p (Last s) rest | p < 4 = "last " ++ showsPrec 4 s rest
   showsPrec p (Prefix s) rest | p < 4 = "prefix " ++ showsPrec 4 s rest
   showsPrec p (Suffix s) rest | p < 4 = "suffix " ++ showsPrec 4 s rest
   showsPrec p (Prepend s) rest | p < 4 = "prepend " ++ showsPrec 4 s rest
   showsPrec p (Append s) rest | p < 4 = "append " ++ showsPrec 4 s rest
   showsPrec p (Substitute s) rest | p < 4 = "substitute " ++ showsPrec 4 s rest
   showsPrec p (StartOf s) rest | p < 4 = "start-of " ++ showsPrec 4 s rest
   showsPrec p (EndOf s) rest | p < 4 = "end-of " ++ showsPrec 4 s rest
   showsPrec _ ExecuteTransducer rest = "execute" ++ rest
   showsPrec _ IdentityTransducer rest = "id" ++ rest
   showsPrec _ Count rest = "count" ++ rest
   showsPrec _ Concatenate rest = "concatenate" ++ rest
   showsPrec _ Group rest = "group" ++ rest
   showsPrec _ Unparse rest = "unparse" ++ rest
   showsPrec _ Uppercase rest = "uppercase" ++ rest
   showsPrec _ ShowTransducer rest = "show" ++ rest
   showsPrec _ EverythingSplitter rest = "everything" ++ rest
   showsPrec _ NothingSplitter rest = "nothing" ++ rest
   showsPrec _ WhitespaceSplitter rest = "whitespace" ++ rest
   showsPrec _ LineSplitter rest = "line" ++ rest
   showsPrec _ LetterSplitter rest = "letters" ++ rest
   showsPrec _ DigitSplitter rest = "digits" ++ rest
   showsPrec _ MarkedSplitter rest = "marked" ++ rest
   showsPrec _ OneSplitter rest = "one" ++ rest
   showsPrec _ (SubstringSplitter s) rest = "substring " ++ shows s (' ' : rest)
   showsPrec _ XMLTokenParser rest = "XML.parse" ++ rest
   showsPrec _ XMLElement rest = "XML.element" ++ rest
   showsPrec _ XMLAttribute rest = "XML.attribute" ++ rest
   showsPrec _ XMLAttributeName rest = "XML.attribute-name" ++ rest
   showsPrec _ XMLAttributeValue rest = "XML.attribute-value" ++ rest
   showsPrec _ XMLElementContent rest = "XML.element-content" ++ rest
   showsPrec _ XMLElementName rest = "XML.element-name" ++ rest
   showsPrec p (XMLElementHavingTag s) rest = "XML.element-having-tag " ++ showsPrec 4 s (' ' : rest)
   showsPrec _ (TypeError tag1 tag2 e) rest = ("Type error: expecting " ++ show tag2 ++ ", received " ++ show tag1
                                               ++ "\nin expression " ++ showsPrec 9 e rest)
   showsPrec p e rest | p > 0 = "(" ++ showsPrec 0 e (')' : rest)

data TypeTag x where
   -- Data type tags
   AnyTag  :: TypeTag ()
   UnitTag  :: TypeTag ()
   CharTag :: TypeTag Char
   TextTag :: TypeTag Text
   IntTag  :: TypeTag Integer
   XMLTokenTag :: TypeTag XMLToken
   EitherTag :: TypeTag x -> TypeTag y -> TypeTag (Either x y)
   ListTag  :: TypeTag x -> TypeTag [x]
   MaybeTag  :: TypeTag x -> TypeTag (Maybe x)
   PairTag :: TypeTag x -> TypeTag y -> TypeTag (x, y)
   MarkupTag :: TypeTag x -> TypeTag y -> TypeTag (Markup x y)
   
   -- Streaming component type tags
   ComponentTag  :: TypeTag x -> TypeTag (Component x)
   CommandTag    :: TypeTag (Performer IO ())
   ConsumerTag   :: Monoid x => TypeTag x -> TypeTag (Consumer IO x ())
   ProducerTag   :: Monoid x => TypeTag x -> TypeTag (Producer IO x ())
   SplitterTag   :: Monoid x => TypeTag x -> TypeTag (Splitter IO x)
   TransducerTag :: (Monoid x, Monoid y) => TypeTag x -> TypeTag y -> TypeTag (Transducer IO x y)
   GenericInputTag :: (TypeTag x -> TypeTag y) -> TypeTag y

instance Show (TypeTag x) where
   show AnyTag = "Any"
   show UnitTag = "()"
   show CharTag = "Char"
   show TextTag = "Text"
   show IntTag = "Int"
   show XMLTokenTag = "XML.Token"
   show (ListTag x) = '[' : shows x "]"
   show (MaybeTag x) = "Maybe " ++ show x
   show (EitherTag x y) = "Either " ++ shows x (" " ++ show y)
   show (MarkupTag x y) = "Markup " ++ shows x (" " ++ show y)
   show (PairTag x y) = "(" ++ shows x (", " ++ shows y ")")
   show (ComponentTag c) = show c
   show CommandTag  = "Command"
   show (ConsumerTag x) = "Consumer " ++ show x
   show (ProducerTag x) = "Producer " ++ show x
   show (SplitterTag x) = "Splitter " ++ show x
   show (TransducerTag x y) = "Transducer " ++ shows x (" -> " ++ show y)
   show GenericInputTag{} = "Generic"

data CComponent c x = CComponent (c (Component x))
instance Functor c => Functor (CComponent c) where
   fmap f (CComponent c) = CComponent (fmap (fmap f) c)

typecast :: forall a b c. TypeTag a -> TypeTag b -> c a -> Maybe (c b)
typecast tag1 tag2 x = case relateTags tag1 tag2 
                       of IdentityRelation{} -> Just x
                          _ -> Nothing

trycast :: forall a b. TypeTag a -> TypeTag b -> a -> Expression -> (b -> Expression) -> Expression
trycast tag1 tag2 x e constructor = case typecast tag1 tag2 (Just x)
                                    of Just (Just y) -> constructor y
                                       Nothing -> TypeError tag1 tag2 e

typecoerce :: forall a b c. Functor c => TypeTag a -> TypeTag b -> c a -> Maybe (c b)
typecoerce (ComponentTag (ProducerTag tag1)) (ComponentTag (ProducerTag tag2)) x = 
   case relateTags tag1 tag2
   of IdentityRelation{} -> Just x
      CoercibleRelation{} -> Just (fmap (>-> coerce) x)
      NoRelation -> Nothing
typecoerce (ComponentTag (ConsumerTag tag1)) (ComponentTag (ConsumerTag tag2)) x = 
   case relateTags tag2 tag1
   of IdentityRelation{} -> Just x
      CoercibleRelation{} -> Just (fmap (coerce >->) x)
      NoRelation -> Nothing
typecoerce (ComponentTag (TransducerTag tag1a tag1b)) (ComponentTag (TransducerTag tag2a tag2b)) x =
   case (relateTags tag2a tag1a, relateTags tag1b tag2b)
   of (IdentityRelation{}, IdentityRelation{}) -> Just x
      (CoercibleRelation{}, IdentityRelation{}) -> Just (fmap (coerce >->) x) 
      (IdentityRelation{}, CoercibleRelation{}) -> Just (fmap (>-> coerce) x)
      _ -> Nothing
typecoerce (ComponentTag (SplitterTag tag1)) (ComponentTag (SplitterTag tag2)) x = 
   case (relateTags tag1 tag2, relateTags tag2 tag1)
   of (IdentityRelation{}, IdentityRelation{}) -> Just x
      (CoercibleRelation{}, CoercibleRelation{}) -> Just (fmap adaptSplitter x)
      _ -> Nothing
typecoerce (ComponentTag a) (ComponentTag b) x = fmap (\(CComponent y)-> y) (typecoerce a b (CComponent x))
typecoerce (ProducerTag tag1) (ProducerTag tag2) x = 
   case relateTags tag1 tag2
   of IdentityRelation{} -> Just x
      CoercibleRelation{} -> Just (fmap (\x-> compose sequentialBinder x Coercions.coerce) x)
      NoRelation -> Nothing
typecoerce tag1 tag2 x = typecast tag1 tag2 x

trycoerce :: forall a b. TypeTag a -> TypeTag b -> a -> Expression -> (b -> Expression) -> Expression
trycoerce tag1 tag2 x e constructor = case typecoerce tag1 tag2 (Just x)
                                      of Just (Just y) -> constructor y
                                         Nothing -> TypeError tag1 tag2 e

tryComponentCast :: forall a b. TypeTag a -> TypeTag b -> Component a -> Expression -> (Component b -> Expression)
                 -> Expression
tryComponentCast tag1 tag2 = trycoerce (ComponentTag tag1) (ComponentTag tag2)

data TypeTagRelation x y where
   CoercibleRelation :: Coercions.Coercible x y => TypeTag x -> TypeTag y -> TypeTagRelation x y
   IdentityRelation :: TypeTag x -> TypeTagRelation x x
   NoRelation :: TypeTagRelation x y

data TypeTagClass x where
   EqClass :: Eq x => TypeTag x -> TypeTagClass x
   ListClass :: x ~ [y] => TypeTag x -> TypeTagClass x
   MonoidClass :: Monoid x => TypeTag x -> TypeTagClass x
   MonoidNullClass :: MonoidNull x => TypeTag x -> TypeTagClass x
   FactorialMonoidClass :: FactorialMonoid x => TypeTag x -> TypeTagClass x
   ShowClass :: Show x => TypeTag x -> TypeTagClass x
   NoClass :: TypeTagClass x

relateTags :: forall a b. TypeTag a -> TypeTag b -> TypeTagRelation a b

relateTags CharTag CharTag = IdentityRelation CharTag
relateTags TextTag TextTag = IdentityRelation TextTag
relateTags IntTag IntTag = IdentityRelation IntTag
relateTags UnitTag UnitTag = IdentityRelation UnitTag
relateTags XMLTokenTag XMLTokenTag = IdentityRelation XMLTokenTag
relateTags (ListTag CharTag) (ListTag TextTag) = CoercibleRelation (ListTag CharTag) (ListTag TextTag)
relateTags (ListTag CharTag) TextTag = CoercibleRelation (ListTag CharTag) TextTag
relateTags (ListTag TextTag) (ListTag CharTag) = CoercibleRelation (ListTag TextTag) (ListTag CharTag)
relateTags TextTag (ListTag CharTag) = CoercibleRelation TextTag (ListTag CharTag)
relateTags (ListTag tag1@MarkupTag{}) (ListTag tag2@MarkupTag{}) = 
   case relateTags tag1 tag2
   of IdentityRelation tag' -> IdentityRelation (ListTag tag')
      _ -> NoRelation
relateTags (ListTag (MarkupTag tag1b tag1)) (ListTag tag2) = 
   case relateTags (ListTag tag1) (ListTag tag2)
   of IdentityRelation (ListTag tag') -> CoercibleRelation (ListTag (MarkupTag tag1b tag')) (ListTag tag')
      CoercibleRelation (ListTag tag1') (ListTag tag2') -> 
         CoercibleRelation (ListTag (MarkupTag tag1b tag1')) (ListTag tag2')
      NoRelation -> NoRelation
relateTags (ListTag tag1) (ListTag tag2) = 
   case relateTags tag1 tag2
   of IdentityRelation tag' -> IdentityRelation (ListTag tag')
      CoercibleRelation tag1' tag2' -> NoRelation -- CoercibleRelation (ListTag tag1') (ListTag tag2')
      NoRelation -> NoRelation
relateTags (MaybeTag tag1) (MaybeTag tag2) = 
   case relateTags tag1 tag2 
   of IdentityRelation tag' -> IdentityRelation (MaybeTag tag')
      CoercibleRelation tag1' tag2' -> NoRelation -- CoercibleRelation (MaybeTag tag1') (MaybeTag tag2')
      NoRelation -> NoRelation
relateTags (EitherTag tag1a tag1b) (EitherTag tag2a tag2b)
   | IdentityRelation tag'a <- relateTags tag1a tag2a,
     IdentityRelation tag'b <- relateTags tag1b tag2b = IdentityRelation (EitherTag tag'a tag'b)
relateTags (MarkupTag tag1b tag1) (MarkupTag tag2b tag2)
   | IdentityRelation tag'b <- relateTags tag1b tag2b,
     IdentityRelation tag' <- relateTags tag1 tag2 = IdentityRelation (MarkupTag tag'b tag')
relateTags (PairTag tag1a tag1b) (PairTag tag2a tag2b)
   | IdentityRelation tag'a <- relateTags tag1a tag2a,
     IdentityRelation tag'b <- relateTags tag1b tag2b = IdentityRelation (PairTag tag'a tag'b)
relateTags CommandTag CommandTag = IdentityRelation CommandTag
relateTags (ConsumerTag tag1) (ConsumerTag tag2)
   | IdentityRelation tag' <- relateTags tag1 tag2 = IdentityRelation (ConsumerTag tag')
relateTags (ProducerTag tag1) (ProducerTag tag2)
   | IdentityRelation tag' <- relateTags tag1 tag2 = IdentityRelation (ProducerTag tag')
relateTags (TransducerTag tag1a tag1b) (TransducerTag tag2a tag2b)
   | IdentityRelation tag'a <- relateTags tag1a tag2a,
     IdentityRelation tag'b <- relateTags tag1b tag2b = IdentityRelation (TransducerTag tag'a tag'b)
relateTags (SplitterTag tag1) (SplitterTag tag2) 
   | IdentityRelation tag' <- relateTags tag1 tag2 = IdentityRelation (SplitterTag tag')
relateTags (ComponentTag tag1) (ComponentTag tag2)
   | IdentityRelation tag' <- relateTags tag1 tag2 = IdentityRelation (ComponentTag tag')
relateTags _ _ = NoRelation

constrainEq :: TypeTag x -> TypeTagClass x
constrainEq CharTag = EqClass CharTag
constrainEq TextTag = EqClass TextTag
constrainEq IntTag = EqClass IntTag
constrainEq UnitTag = EqClass UnitTag
constrainEq XMLTokenTag = EqClass XMLTokenTag
constrainEq (ListTag tag) | EqClass tag' <- constrainEq tag = EqClass (ListTag tag')
constrainEq (MaybeTag tag) | EqClass tag' <- constrainEq tag = EqClass (MaybeTag tag')
constrainEq (PairTag tag1 tag2)
   | EqClass tag1' <- constrainEq tag1, EqClass tag2' <- constrainEq tag2 = EqClass (PairTag tag1' tag2')
constrainEq (EitherTag tag1 tag2)
   | EqClass tag1' <- constrainEq tag1, EqClass tag2' <- constrainEq tag2 = EqClass (EitherTag tag1' tag2')
constrainEq (MarkupTag tag1 tag2)
   | EqClass tag1' <- constrainEq tag1, EqClass tag2' <- constrainEq tag2 = EqClass (MarkupTag tag1' tag2')
constrainEq _ = NoClass

constrainList :: TypeTag x -> TypeTagClass x
constrainList tag@ListTag{} = ListClass tag
constrainList _ = NoClass

constrainShow :: TypeTag x -> TypeTagClass x
constrainShow CharTag = ShowClass CharTag
constrainShow TextTag = ShowClass TextTag
constrainShow IntTag = ShowClass IntTag
constrainShow UnitTag = ShowClass UnitTag
constrainShow XMLTokenTag = ShowClass XMLTokenTag
constrainShow (ListTag tag) | ShowClass tag' <- constrainShow tag = ShowClass (ListTag tag')
constrainShow (MaybeTag tag) | ShowClass tag' <- constrainShow tag = ShowClass (MaybeTag tag')
constrainShow (PairTag tag1 tag2)
   | ShowClass tag1' <- constrainShow tag1, ShowClass tag2' <- constrainShow tag2 = ShowClass (PairTag tag1' tag2')
constrainShow (EitherTag tag1 tag2)
   | ShowClass tag1' <- constrainShow tag1, ShowClass tag2' <- constrainShow tag2 = ShowClass (EitherTag tag1' tag2')
constrainShow (MarkupTag tag1 tag2)
   | ShowClass tag1' <- constrainShow tag1, ShowClass tag2' <- constrainShow tag2 = ShowClass (MarkupTag tag1' tag2')
constrainShow _ = NoClass

constrainMonoid :: TypeTag x -> TypeTagClass x
constrainMonoid TextTag = MonoidClass TextTag
constrainMonoid UnitTag = MonoidClass UnitTag
constrainMonoid tag@ListTag{} = MonoidClass tag
constrainMonoid _ = NoClass

constrainMonoidNull :: TypeTag x -> TypeTagClass x
constrainMonoidNull TextTag = MonoidNullClass TextTag
constrainMonoidNull UnitTag = MonoidNullClass UnitTag
constrainMonoidNull tag@ListTag{} = MonoidNullClass tag
constrainMonoidNull _ = NoClass

constrainFactorialMonoid :: TypeTag x -> TypeTagClass x
constrainFactorialMonoid TextTag = FactorialMonoidClass TextTag
constrainFactorialMonoid tag@ListTag{} = FactorialMonoidClass tag
constrainFactorialMonoid _ = NoClass

data Flag = Command | Help | Interactive | PrettyPrint | ScriptFile String | StandardInput | Threads String
            deriving Eq

data InputSource = UnspecifiedSource | CommandLineSource | InteractiveSource | ScriptFileSource String | StandardInputSource

data Flags = Flags {helpFlag :: Bool,
                    inputSourceFlag :: InputSource,
                    prettyPrintFlag :: Bool,
                    threadCount :: Maybe Int}

flagList = [Option "c" ["command"] (NoArg Command) "Execute a single command",
            Option "p" ["prettyprint"] (NoArg PrettyPrint) "Pretty print the input expression instead of executing it",
            Option "h" ["help"] (NoArg Help) "Show help",
            Option "f" ["file"] (ReqArg ScriptFile "file") "Execute commands from a script file",
            Option "i" ["interactive"] (NoArg Interactive) "Execute commands interactively",
            Option "s" ["stdin"] (NoArg StandardInput) "Execute commands from the standard input",
            Option "t" ["threads"] (ReqArg Threads "threads") "Specify number of threads to use"]

usageSyntax = "Usage: shsh (-c <command> | -f <file> | -i | -s) "

main = do args <- getArgs
          let (specifiedOptions, arguments, errors) = getOpt Permute flagList args
              emptyOptions = Flags {helpFlag = False,
                                    inputSourceFlag = UnspecifiedSource,
                                    prettyPrintFlag = False,
                                    threadCount = Nothing}
              options = foldr extractOption emptyOptions specifiedOptions
              extractOption Command options@Flags{inputSourceFlag= UnspecifiedSource}
                 = options{inputSourceFlag= CommandLineSource}
              extractOption Help options = options{helpFlag= True}
              extractOption Interactive options@Flags{inputSourceFlag= UnspecifiedSource}
                 = options{inputSourceFlag= InteractiveSource}
              extractOption StandardInput options@Flags{inputSourceFlag= UnspecifiedSource}
                 = options{inputSourceFlag= StandardInputSource}
              extractOption PrettyPrint options = options{prettyPrintFlag= True}
              extractOption (ScriptFile name) options@Flags{inputSourceFlag= UnspecifiedSource}
                 = options{inputSourceFlag= ScriptFileSource name}
              extractOption (Threads count) options@Flags{threadCount= Nothing} = options{threadCount= Just (read count)}
          if not (null errors) || helpFlag options
             then showHelp
             else case inputSourceFlag options
                  of CommandLineSource -> interpret options (concat (intersperse " " arguments)) >> return ()
                     InteractiveSource -> runInputT defaultSettings $ interact options
                     ScriptFileSource name -> readFile name >>= interpret options >> return ()
                     StandardInputSource -> getContents >>= interpret options >> return ()
                     UnspecifiedSource -> runInputT defaultSettings $ interact options

prettyprint options expression = print expression
                                 >> case compile UnitTag expression
                                    of Compiled tag component ->
                                          putStrLn "::" >> print tag
                                          >> putStrLn (showComponentTree $ adjust options component)
                                       e@TypeError{} -> print e

showHelp = putStrLn (usageInfo usageSyntax flagList)

interact :: Flags -> InputT IO ()
interact options = do command <- getInputLine "> "
                      finish <- maybe (pure False) (lift . interpret options) command
                      when (not finish) (interact options)

interpret :: Flags -> String -> IO Bool
interpret options command = case parseExpression command
                            of Left position -> hPutStrLn stderr ("Error at " ++ show position) >> return False
                               Right (Exit, "", _) -> return True
                               Right (expression, "", _) -> (if (prettyPrintFlag options)
                                                             then prettyprint options expression
                                                             else case compile UnitTag expression
                                                                  of e@Compiled{} -> execute options e
                                                                     e@TypeError{} -> print e)
                                                            >> return False
                               Right (expression, rest, _) -> hPutStrLn stderr ("Cannot parse \"" ++ rest
                                                                           ++ "\"\nafter " ++ show expression)
                                                              >> return False

execute :: Flags -> Expression -> IO ()
execute options (Compiled CommandTag command) = perform $ with $ adjust options command
execute options e@(Compiled t@ProducerTag{} p) =
   case typecoerce t (ProducerTag $ TextTag) p
   of Just producer-> runCoroutine (pipe
                                       (produce $ with $ adjust options producer)
                                       (consume $ with toStdOut))
                      >> hFlush stdout
      Nothing -> print (TypeError t (ProducerTag $ ListTag CharTag) e)
execute options (Compiled tag _) = hPutStrLn stderr ("Expecting a command or a Producer Char, received a " ++ show tag)

adjust Flags{threadCount= Just threads} component = usingThreads component threads
adjust _ component = component

compile :: TypeTag x -> Expression -> Expression
compile _ e@Compiled{} = e
compile _ e@TypeError{} = e
compile inputTag (Pipe left right)
   = case compile inputTag left
     of Compiled tag@(ProducerTag tag1) p
           -> case compile tag1 right
              of Compiled (ConsumerTag tag2) c -> tryComponentCast tag (ProducerTag tag2) p left $
                                                  \p'-> Compiled CommandTag (p' >-> c)
                 Compiled (TransducerTag tag2 tag3) t -> tryComponentCast tag (ProducerTag tag2) p left $
                                                         \p'-> Compiled (ProducerTag tag3) (p' >-> t)
                 e@TypeError{} -> e
                 Compiled tag _ -> TypeError tag (TransducerTag tag1 AnyTag) right
        Compiled (TransducerTag tag1 tag2) t
           -> case compile tag2 right
              of Compiled tag3@ConsumerTag{} c -> tryComponentCast tag3 (ConsumerTag tag2) c right $
                                                  \c'-> Compiled (ConsumerTag tag1) (t >-> c')
                 Compiled tag@(TransducerTag tag3 tag4) t2 -> tryComponentCast tag (TransducerTag tag2 tag4) t2 right $
                                                              \t2'-> Compiled (TransducerTag tag1 tag4) (t >-> t2')
                 e@TypeError{} -> e
                 Compiled tag _ -> TypeError tag (TransducerTag tag2 AnyTag) right
        Compiled tag _ -> TypeError tag (ProducerTag AnyTag) left
        e@TypeError{} -> e
compile _ (FileProducer path) = Compiled (ProducerTag TextTag) (fromFile path)
compile _ StdInProducer = Compiled (ProducerTag TextTag) fromStdIn
compile _ (ProduceFrom string) = Compiled (ProducerTag $ ListTag CharTag) (atomic "putAll" 1 $ Producer $
                                                                           \sink-> putAll string sink >> return ())
compile _ (FileConsumer path) = Compiled (ConsumerTag TextTag) (toFile path)
compile _ (FileAppend path) = Compiled (ConsumerTag TextTag) (appendFile path)
compile inputTag Suppress | MonoidClass{} <- constrainMonoid inputTag = Compiled (ConsumerTag inputTag) suppress
compile inputTag (ErrorConsumer message) | MonoidNullClass{} <- constrainMonoidNull inputTag =
   Compiled (ConsumerTag inputTag) (erroneous message)
compile inputTag (Sequence e1 e2) = compileJoin sequence inputTag e1 e2
compile inputTag (Join e1 e2) = compileJoin join inputTag e1 e2
compile inputTag (ForEach splitter true false) = combineSplitterAndBranches foreach inputTag splitter true false
compile inputTag (If splitter true false) | MonoidClass{} <- constrainMonoid inputTag =
   combineSplitterAndBranches ifs inputTag splitter true false
compile UnitTag (NativeCommand command)
   = Compiled (ProducerTag TextTag) $
     atomic command ioCost $ Producer $
     \sink-> do (Nothing, Just stdout, Nothing, pid)
                   <- lift (Process.createProcess (Process.shell command){Process.std_out= Process.CreatePipe})
                produce (with $ fromHandle stdout) sink
                lift (hClose stdout)
compile _ (NativeCommand command) = 
   Compiled (TransducerTag (ListTag CharTag) (ListTag CharTag)) (atomic command ioCost $ Transducer f)
   where f :: forall a1 a2 d. OpenTransducer IO a1 a2 d String String ()
         f source sink = do (Just stdin, Just stdout, Nothing, pid)
                               <- lift (Process.createProcess
                                           (Process.shell command){Process.std_in= Process.CreatePipe,
                                                                   Process.std_out= Process.CreatePipe})
                            lift (hSetBuffering stdin NoBuffering
                                  >> hSetBuffering stdout NoBuffering)
                            interleave source stdin pid stdout sink
         interleave :: forall a1 a2 d. (AncestorFunctor a1 d, AncestorFunctor a2 d) =>
                       Source IO a1 [Char] -> Handle -> Process.ProcessHandle -> Handle -> Sink IO a2 [Char]
                    -> Coroutine d IO ()
         interleave source stdin pid stdout sink = interleave1
            where interleave1 = get source
                                >>= maybe
                                       (lift (hClose stdin) >> interleaveEnd)
                                       (\x-> lift (Process.getProcessExitCode pid)
                                             >>= maybe
                                                    (lift (hPutChar stdin x) >> interleave2)
                                                    (const interleave2))
                  interleave2 = lift (hReady stdout)
                                >>= flip when (lift (hGetChar stdout)
                                               >>= put sink)
                                >> interleave1
                  interleaveEnd = do eof <- lift (hIsEOF stdout)
                                     if eof
                                        then lift $ hClose stdout
                                        else lift (hGetChar stdout)
                                             >>= put sink
                                             >> interleaveEnd
compile inputTag (Select e) | MonoidClass{} <- constrainMonoid inputTag = 
   case compile inputTag e
   of Compiled (SplitterTag tag) s -> Compiled (TransducerTag tag tag) (select s)
      Compiled tag _ -> TypeError tag (SplitterTag inputTag) e
      e'@TypeError{} -> e'
compile inputTag (While condition body)
   = case (compile inputTag condition, compile inputTag body)
     of (Compiled (SplitterTag tag1) s, Compiled tag2@TransducerTag{} t)
           | MonoidNullClass{} <- constrainMonoidNull tag1
           -> let tag2' = TransducerTag tag1 tag1
              in tryComponentCast tag2 tag2' t body (\t'-> Compiled tag2' (while t' s))
compile inputTag (FollowedBy left right) = combineFactorialSplitters followedBy inputTag left right
compile inputTag (And left right) = combineSplitters (>&) inputTag left right
compile inputTag (Or left right) = combineSplitters (>|) inputTag left right
compile inputTag (ZipWithAnd left right) = combineFactorialSplitters (Combinators.&&) inputTag left right
compile inputTag (ZipWithOr left right) = combineFactorialSplitters (Combinators.||) inputTag left right
compile inputTag (Nested left right) = combineNullSplitters nestedIn inputTag left right
compile inputTag (Having left right) = combineSplittersOfCoercibleTypes having inputTag left right
compile inputTag (HavingOnly left right) = combineSplittersOfCoercibleTypes havingOnly inputTag left right
compile inputTag (Between left right) = combineFactorialSplitters (...) inputTag left right
compile inputTag (Not splitter) | MonoidClass{} <- constrainMonoid inputTag = wrapSplitter snot inputTag splitter
compile inputTag (First splitter) = wrapMonoidNullSplitter first inputTag splitter
compile inputTag (Last splitter) = wrapMonoidNullSplitter last inputTag splitter
compile inputTag (Prefix splitter) = wrapMonoidNullSplitter prefix inputTag splitter
compile inputTag (Suffix splitter) = wrapMonoidNullSplitter suffix inputTag splitter
compile inputTag (StartOf splitter) = wrapMonoidNullSplitter startOf inputTag splitter
compile inputTag (EndOf splitter) = wrapMonoidNullSplitter endOf inputTag splitter
compile inputTag (Prepend prefix) | MonoidClass{} <- constrainMonoid inputTag =
   wrapProducerIntoTransducer prepend inputTag prefix
compile inputTag (Append suffix) | MonoidClass{} <- constrainMonoid inputTag =
   wrapProducerIntoTransducer append inputTag suffix
compile inputTag (Substitute replacement) | MonoidClass{} <- constrainMonoid inputTag =
   wrapGenericProducerIntoTransducer substitute inputTag replacement
compile _ ExecuteTransducer
   = Compiled (TransducerTag (ListTag CharTag) TextTag) (atomic "execute" ioCost $ Transducer execute)
     where execute :: forall a1 a2 d. OpenTransducer IO a1 a2 d String Text ()
           execute source sink = do let (source' :: Source IO d String) = liftSource source
                                    ((), command) <- pipe (pour_ source') getAll
                                    (Nothing, Just stdout, Nothing, pid)
                                       <- lift (Process.createProcess
                                                   (Process.shell command){Process.std_out= Process.CreatePipe})
                                    produce (with $ fromHandle stdout) sink
                                    lift (hClose stdout)

compile inputTag IdentityTransducer | MonoidClass{} <- constrainMonoid inputTag =
   Compiled (TransducerTag inputTag inputTag) id
compile inputTag Count | FactorialMonoidClass{} <- constrainFactorialMonoid inputTag =
   Compiled (TransducerTag inputTag (ListTag IntTag)) count
compile inputTag@(ListTag itemTag) Concatenate
   | MonoidClass{} <- constrainMonoid itemTag = Compiled (TransducerTag inputTag itemTag) concatenate
compile inputTag Concatenate = TypeError inputTag (ListTag AnyTag) Concatenate
compile inputTag Group | MonoidClass{} <- constrainMonoid inputTag =
   Compiled (TransducerTag inputTag (ListTag inputTag)) group
compile t@(ListTag (MarkupTag t1 t2)) Unparse 
   | MonoidClass{} <- constrainMonoid t2 = Compiled (TransducerTag t t2) unparse
compile inputTag Unparse | MonoidClass{} <- constrainMonoid inputTag = 
   TypeError (TransducerTag (ListTag $ MarkupTag AnyTag AnyTag) AnyTag) (TransducerTag inputTag AnyTag) Unparse
compile _ Uppercase = Compiled (TransducerTag (ListTag CharTag) (ListTag CharTag)) uppercase
compile inputTag@(ListTag itemTag) ShowTransducer | ShowClass{} <- constrainShow itemTag = 
   Compiled (TransducerTag inputTag (ListTag $ ListTag CharTag)) toString
compile inputTag ShowTransducer | MonoidClass{} <- constrainMonoid inputTag =
   TypeError (TransducerTag (ListTag IntTag) (ListTag $ ListTag CharTag)) (TransducerTag inputTag AnyTag) ShowTransducer
compile inputTag EverythingSplitter | MonoidClass{} <- constrainMonoid inputTag =
   Compiled (SplitterTag inputTag) everything
compile inputTag NothingSplitter | MonoidClass{} <- constrainMonoid inputTag =
   Compiled (SplitterTag inputTag) nothing
compile _ WhitespaceSplitter = Compiled (SplitterTag (ListTag CharTag)) whitespace
compile _ LineSplitter = Compiled (SplitterTag (ListTag CharTag)) line
compile _ LetterSplitter = Compiled (SplitterTag (ListTag CharTag)) letters
compile _ DigitSplitter = Compiled (SplitterTag (ListTag CharTag)) digits
compile inputTag@(ListTag (MarkupTag tag _)) MarkedSplitter
   | EqClass{} <- constrainEq tag = Compiled (SplitterTag inputTag) marked
compile _ MarkedSplitter = Compiled (SplitterTag (ListTag $ MarkupTag AnyTag AnyTag)) marked
compile inputTag OneSplitter | FactorialMonoidClass{} <- constrainFactorialMonoid inputTag =
   Compiled (SplitterTag inputTag) one
-- compile inputTag (SubstringSplitter part) | FactorialMonoidClass{} <- constrainFactorialMonoid inputTag =
--    Compiled (SplitterTag inputTag) (substring part)
compile _ (SubstringSplitter part) = Compiled (SplitterTag (ListTag CharTag)) (substring part)
compile _ XMLTokenParser = Compiled (TransducerTag TextTag (ListTag $ MarkupTag XMLTokenTag TextTag)) xmlParseTokens
compile _ XMLElement = Compiled (SplitterTag (ListTag $ MarkupTag XMLTokenTag TextTag)) xmlElement
compile _ XMLAttribute = Compiled (SplitterTag (ListTag $ MarkupTag XMLTokenTag TextTag)) xmlAttribute
compile _ XMLAttributeName = Compiled (SplitterTag (ListTag $ MarkupTag XMLTokenTag TextTag)) xmlAttributeName
compile _ XMLAttributeValue = Compiled (SplitterTag (ListTag $ MarkupTag XMLTokenTag TextTag)) xmlAttributeValue
compile _ XMLElementContent = Compiled (SplitterTag (ListTag $ MarkupTag XMLTokenTag TextTag)) xmlElementContent
compile _ XMLElementName = Compiled (SplitterTag (ListTag $ MarkupTag XMLTokenTag TextTag)) xmlElementName
compile _ (XMLElementHavingTag s) = 
   wrapConcreteSplitter xmlElementHavingTagWith (ListTag $ MarkupTag XMLTokenTag TextTag) s

compile inputTag expression = error ("Cannot compile " ++ show expression ++ " with input " ++ show inputTag)

compileJoin :: forall t.
               (forall t1 t2 t3 m x y c1 c2 c3. (MonadParallel m, JoinableComponentPair t1 t2 t3 m x y c1 c2 c3) => 
                Component c1 -> Component c2 -> Component c3)
               -> TypeTag t -> Expression -> Expression -> Expression
compileJoin combinator inputTag e1 e2
   = case (compile inputTag e1, compile inputTag e2)
     of (Compiled CommandTag c1, Compiled CommandTag c2) -> Compiled CommandTag (combinator c1 c2)
        (Compiled tag1@ProducerTag{} p1, Compiled tag2@ProducerTag{} p2)
           -> tryComponentCast tag2 tag1 p2 e2 (\p2'-> Compiled tag1 (combinator p1 p2'))
        (Compiled tag1@ConsumerTag{} c1, Compiled tag2@ConsumerTag{} c2)
           -> tryComponentCast tag2 tag1 c2 e2 (\c2'-> Compiled tag1 (combinator c1 c2'))
        (Compiled tag1@TransducerTag{} t1, Compiled tag2@TransducerTag{} t2)
           -> tryComponentCast tag2 tag1 t2 e2 (\t2'-> Compiled tag1 (combinator t1 t2'))
        (Compiled CommandTag c, Compiled tag@ProducerTag{} p) -> Compiled tag (combinator c p)
        (Compiled tag@ProducerTag{} p, Compiled CommandTag c) -> Compiled tag (combinator p c)
        (Compiled CommandTag c1, Compiled tag@ConsumerTag{} c2) -> Compiled tag (combinator c1 c2)
        (Compiled tag@ConsumerTag{} c1, Compiled CommandTag c2) -> Compiled tag (combinator c1 c2)
        (Compiled CommandTag c, Compiled tag@TransducerTag{} t) -> Compiled tag (combinator c t)
        (Compiled tag@TransducerTag{} t, Compiled CommandTag c) -> Compiled tag (combinator t c)
        (Compiled (ProducerTag tag1) p, Compiled (ConsumerTag tag2) c)
           -> Compiled (TransducerTag tag2 tag1) (combinator p c)
        (Compiled (ConsumerTag tag1) p, Compiled (ProducerTag tag2) c)
           -> Compiled (TransducerTag tag1 tag2) (combinator p c)
        (Compiled (ProducerTag tag1) p, Compiled tag@(TransducerTag tag2 tag3) t)
           -> let tag' = TransducerTag tag2 tag1
              in tryComponentCast tag tag' t e2 (\t'-> Compiled tag' (combinator p t'))
        (Compiled tag@(TransducerTag tag1 tag2) t, Compiled tag3@ProducerTag{} p)
           -> let tag' = TransducerTag tag2 tag1
              in tryComponentCast tag3 (ProducerTag tag2) p e2 (\p'-> Compiled tag (combinator t p'))
        (Compiled (ConsumerTag tag1) c, Compiled tag@(TransducerTag tag2 tag3) t)
           -> let tag' = TransducerTag tag1 tag3
              in tryComponentCast tag tag' t e2 (\t'-> Compiled tag' (combinator c t'))
        (Compiled tag@(TransducerTag tag1 tag2) t, Compiled tag3@ConsumerTag{} c)
           -> let tag' = TransducerTag tag2 tag1
              in tryComponentCast tag3 (ConsumerTag tag1) c e2 (\c'-> Compiled tag (combinator t c'))
        (e@TypeError{}, _) -> e
        (_, e@TypeError{}) -> e
        (Compiled tag@SplitterTag{} _, _) -> TypeError tag (ProducerTag AnyTag) e1
        (_, Compiled tag@SplitterTag{} _) -> TypeError tag (ProducerTag AnyTag) e2

wrapSplitter :: forall x. Monoid x =>
                (forall x. Monoid x => SplitterComponent IO x -> SplitterComponent IO x) ->
                TypeTag x -> Expression -> Expression
wrapSplitter combinator inputTag expression
   = case compile inputTag expression
     of Compiled tag@(SplitterTag tx) splitter -> Compiled (SplitterTag tx) (combinator splitter)
        Compiled tag _ -> TypeError tag (SplitterTag inputTag) expression
        e@TypeError{} -> e

wrapMonoidNullSplitter :: forall x.
                          (forall x. MonoidNull x => SplitterComponent IO x -> SplitterComponent IO x) ->
                          TypeTag x -> Expression -> Expression
wrapMonoidNullSplitter combinator inputTag expression
   = case compile inputTag expression
     of Compiled tag@(SplitterTag tx) splitter | MonoidNullClass{} <- constrainMonoidNull tx ->
           Compiled (SplitterTag tx) (combinator splitter)
        Compiled tag _ | MonoidClass{} <- constrainMonoid inputTag -> TypeError tag (SplitterTag inputTag) expression
        e@TypeError{} -> e

wrapConcreteSplitter :: forall x. Monoid x =>
                        (SplitterComponent IO x -> SplitterComponent IO x) ->
                        TypeTag x -> Expression -> Expression
wrapConcreteSplitter combinator inputTag expression
   = case compile inputTag expression
     of Compiled tag@(SplitterTag tx) splitter ->
           tryComponentCast tag (SplitterTag inputTag) splitter expression $
                   \s'-> Compiled (SplitterTag inputTag) (combinator s')
        Compiled tag _ -> TypeError tag (SplitterTag inputTag) expression
        e@TypeError{} -> e

wrapConcreteSplitter' :: forall x y. (Monoid x, Monoid y) =>
                         (SplitterComponent IO x -> SplitterComponent IO y) ->
                         TypeTag x -> TypeTag y -> Expression -> Expression
wrapConcreteSplitter' combinator inputTag outputTag expression
   = case compile inputTag expression
     of Compiled tag@(SplitterTag tx) splitter ->
           tryComponentCast tag (SplitterTag inputTag) splitter expression $
                            \s'-> Compiled (SplitterTag outputTag) (combinator s')
        Compiled tag _ -> TypeError tag (SplitterTag inputTag) expression
        e@TypeError{} -> e

wrapProducerIntoTransducer :: forall x. Monoid x =>
                              (ProducerComponent IO x () -> TransducerComponent IO x x) -> TypeTag x -> Expression -> Expression
wrapProducerIntoTransducer combinator inputTag expression
   = case compile inputTag expression
     of Compiled tag@ProducerTag{} p
           -> tryComponentCast tag (ProducerTag inputTag) p expression $
              \p'-> Compiled (TransducerTag inputTag inputTag) (combinator p')
        Compiled tag _ -> TypeError tag (ProducerTag inputTag) expression
        e@TypeError{} -> e

wrapGenericProducerIntoTransducer :: forall x. Monoid x =>
                                     (forall y r. Monoid y => ProducerComponent IO y r -> TransducerComponent IO x y)
                                        -> TypeTag x -> Expression -> Expression
wrapGenericProducerIntoTransducer combinator inputTag expression
   = case compile inputTag expression
     of Compiled (ProducerTag outTag) p -> Compiled (TransducerTag inputTag outTag) (combinator p)
        Compiled tag _ -> TypeError tag (ProducerTag inputTag) expression
        e@TypeError{} -> e

combineSplitters :: forall x.
                    (forall x. Monoid x => SplitterComponent IO x -> SplitterComponent IO x -> SplitterComponent IO x)
                    -> TypeTag x -> Expression -> Expression -> Expression
combineSplitters combinator inputTag left right
   = case (compile inputTag left, compile inputTag right)
     of (Compiled tag1@(SplitterTag x1) s1, Compiled tag2@(SplitterTag x2) s2)
           -> tryComponentCast tag2 (SplitterTag x1) s2 right $
              \s2'-> Compiled (SplitterTag x1) (combinator s1 s2')
        (e@TypeError{}, _) -> e
        (_, e@TypeError{}) -> e
        (Compiled tag1 _, Compiled tag2@SplitterTag{} _) -> TypeError tag1 tag2 left
        (Compiled tag1@SplitterTag{} _, Compiled tag2 _) -> TypeError tag2 tag1 right

combineFactorialSplitters :: forall x c.
                        (forall x. FactorialMonoid x => 
                         SplitterComponent IO x -> SplitterComponent IO x -> SplitterComponent IO x)
                        -> TypeTag x
                        -> Expression -> Expression -> Expression
combineFactorialSplitters combinator inputTag left right
   = case (compile inputTag left, compile inputTag right)
     of (Compiled tag1@(SplitterTag x1) s1, Compiled tag2@(SplitterTag x2) s2)
         | FactorialMonoidClass{} <- constrainFactorialMonoid x1
           -> tryComponentCast tag2 (SplitterTag x1) s2 right $
              \s2'-> Compiled (SplitterTag x1) (combinator s1 s2')
        (e@TypeError{}, _) -> e
        (_, e@TypeError{}) -> e
        (Compiled tag1 _, Compiled tag2@SplitterTag{} _) -> TypeError tag1 tag2 left
        (Compiled tag1@SplitterTag{} _, Compiled tag2 _) -> TypeError tag2 tag1 right

combineNullSplitters :: forall x c.
                        (forall x. MonoidNull x => 
                         SplitterComponent IO x -> SplitterComponent IO x -> SplitterComponent IO x)
                        -> TypeTag x
                        -> Expression -> Expression -> Expression
combineNullSplitters combinator inputTag left right
   = case (compile inputTag left, compile inputTag right)
     of (Compiled tag1@(SplitterTag x1) s1, Compiled tag2@(SplitterTag x2) s2)
         | MonoidNullClass{} <- constrainMonoidNull x1
           -> tryComponentCast tag2 (SplitterTag x1) s2 right $
              \s2'-> Compiled (SplitterTag x1) (combinator s1 s2')
        (e@TypeError{}, _) -> e
        (_, e@TypeError{}) -> e
        (Compiled tag1 _, Compiled tag2@SplitterTag{} _) -> TypeError tag1 tag2 left
        (Compiled tag1@SplitterTag{} _, Compiled tag2 _) -> TypeError tag2 tag1 right

combineSplittersOfCoercibleTypes :: 
   forall x. (forall x y. (MonoidNull x, MonoidNull y, Coercions.Coercible x y) =>
              SplitterComponent IO x -> SplitterComponent IO y -> SplitterComponent IO x)
   -> TypeTag x -> Expression -> Expression -> Expression
combineSplittersOfCoercibleTypes combinator inputTag left right
   = case (compile inputTag left, compile inputTag right)
     of (Compiled ts1@(SplitterTag tag1) s1, Compiled ts2@(SplitterTag tag2) s2)
           | MonoidNullClass{} <- constrainMonoidNull tag1, MonoidNullClass{} <- constrainMonoidNull tag2
           -> case relateTags tag1 tag2
              of IdentityRelation tag'-> Compiled (SplitterTag tag') (combinator s1 s2)
                 CoercibleRelation tag1' tag2'-> Compiled (SplitterTag tag1') (combinator s1 s2)
                 NoRelation -> TypeError ts2 ts1 right
        (e@TypeError{}, _) -> e
        (_, e@TypeError{}) -> e
        (Compiled tag1 _, Compiled tag2@SplitterTag{} _) -> TypeError tag1 tag2 left
        (Compiled tag1@SplitterTag{} _, Compiled tag2 _) -> TypeError tag2 tag1 right

combineSplitterAndBranches :: forall x.
                              (forall x b cc. (MonoidNull x, Branching cc IO x ()) => 
                               SplitterComponent IO x -> Component cc -> Component cc -> Component cc)
                              -> TypeTag x -> Expression -> Expression -> Expression -> Expression
combineSplitterAndBranches combinator inputTag splitter true false
   = case (compile inputTag splitter, compile inputTag true, compile inputTag false)
     of (Compiled (SplitterTag tag1) s, Compiled tag2@ConsumerTag{} t, Compiled tag3@ConsumerTag{} f)
           | MonoidNullClass{} <- constrainMonoidNull tag1
           -> tryComponentCast tag2 (ConsumerTag tag1) t true $
              \t'-> tryComponentCast tag3 (ConsumerTag tag1) f false $
                       \f'-> Compiled (ConsumerTag tag1) (combinator s t' f')
        (Compiled tag1@(SplitterTag tag1i) s, Compiled tag2@SplitterTag{} t, Compiled tag3@SplitterTag{} f)
           | MonoidNullClass{} <- constrainMonoidNull tag1i
           -> tryComponentCast tag2 tag1 t true $
              \t'-> tryComponentCast tag3 tag1 f false $
                       \f'-> Compiled tag1 (combinator s t' f')
        (Compiled (SplitterTag tag1) s, Compiled tag2@(TransducerTag tag2a tag2b) t, Compiled tag3@TransducerTag{} f)
           | MonoidNullClass{} <- constrainMonoidNull tag1
           -> let tag2' = TransducerTag tag1 tag2b
              in tryComponentCast tag2 tag2' t true $
                    \t'-> tryComponentCast tag3 tag2' f false $
                             \f'-> Compiled tag2' (combinator s t' f')
        (Compiled (SplitterTag tag1) s, Compiled tag2@(TransducerTag tag2a tag2b) t, Compiled tag3@ConsumerTag{} f)
           | MonoidNullClass{} <- constrainMonoidNull tag1
           -> let tag2' = TransducerTag tag1 tag2b
              in tryComponentCast tag2 tag2' t true $
                    \t'-> tryComponentCast tag3 (ConsumerTag tag1) f false $
                             \f'-> Compiled tag2' (combinator s t' (consumeBy f'))
        (Compiled (SplitterTag tag1) s, Compiled tag2@ConsumerTag{} t, Compiled tag3@(TransducerTag tag3a tag3b) f)
           | MonoidNullClass{} <- constrainMonoidNull tag1
           -> let tag3' = TransducerTag tag1 tag3b
              in tryComponentCast tag2 (ConsumerTag tag1) t true $
                    \t'-> tryComponentCast tag3 tag3' f false $
                             \f'-> Compiled tag3' (combinator s (consumeBy t') f')
        (Compiled (SplitterTag tag1) s, Compiled tag2@(TransducerTag tag2a tag2b) t, Compiled tag3@ProducerTag{} f)
           | MonoidNullClass{} <- constrainMonoidNull tag1
           -> let tag2' = TransducerTag tag1 tag2b
              in tryComponentCast tag2 tag2' t true $
                    \t'-> tryComponentCast tag3 (ProducerTag tag2b) f false $
                             \f'-> Compiled tag2' (combinator s t' (substitute f'))
        (Compiled (SplitterTag tag1) s, Compiled tag2@ProducerTag{} t, Compiled tag3@(TransducerTag tag3a tag3b) f)
           | MonoidNullClass{} <- constrainMonoidNull tag1
           -> let tag3' = TransducerTag tag1 tag3b
              in tryComponentCast tag2 (ProducerTag tag3b) t true $
                    \t'-> tryComponentCast tag3 tag3' f false $
                             \f'-> Compiled tag3' (combinator s (substitute t') f')
        (Compiled (SplitterTag tag1) s, Compiled tag2@(ConsumerTag tag2a) t, Compiled tag3@(ProducerTag tag3a) f)
           | MonoidNullClass{} <- constrainMonoidNull tag1
           -> tryComponentCast tag2 (ConsumerTag tag1) t true $
                 \t'-> Compiled (TransducerTag tag1 tag3a) (combinator s (consumeBy t') (substitute f))
        (Compiled (SplitterTag tag1) s, Compiled tag2@(ProducerTag tag2a) t, Compiled tag3@(ConsumerTag tag3a) f)
           | MonoidNullClass{} <- constrainMonoidNull tag1
           -> tryComponentCast tag3 (ConsumerTag tag1) f true $
                 \f'-> Compiled (TransducerTag tag1 tag2a) (combinator s (substitute t) (consumeBy f'))
        (e@TypeError{}, _, _) -> e
        (_, e@TypeError{}, _) -> e
        (_, _, e@TypeError{}) -> e
        (Compiled SplitterTag{} _, Compiled tag _, _)
           | MonoidClass{} <- constrainMonoid inputTag -> TypeError tag (TransducerTag inputTag AnyTag) true
        (Compiled SplitterTag{} _, _, Compiled tag _)
           | MonoidClass{} <- constrainMonoid inputTag -> TypeError tag (TransducerTag inputTag AnyTag) false
        (Compiled tag _, _, _) 
           | MonoidClass{} <- constrainMonoid inputTag -> TypeError tag (SplitterTag inputTag) splitter

parseExpression :: String -> Either Int (Expression, [Char], Int)
parseExpression s = case Parsec.parse partialExpressionParser "" s of
   Left error -> Left (sourceLine (errorPos error))
   Right result -> Right result

lexer = (makeTokenParser language) {stringLiteral= stringLexemeParser}

language = emptyDef{commentLine= "#",
                    identLetter= satisfy (\char-> isAlphaNum char || char == '-' || char == '_'),
                    reservedOpNames= ["...", ">!", ">", ">&", ">,", ">>", ">|", "|", "||", ";", "&"],
                    reservedNames= ["append", "concatenate", "count", "digits", "do",
                                    "else", "end", "error", "exit", "everything", "first", "foreach",
                                    "group", "having", "having-only", "id", "if", "in",
                                    "last", "letters", "line", "marked", "nested", "nothing", "prefix", "prepend",
                                    "select", "show", "stdin", "substitute", "substring", "suffix", "suppress",
                                    "then", "unparse", "uppercase", "while", "whitespace",
                                    "XML.parse", "XML.attribute", "XML.attribute-name", "XML.attribute-value",
                                    "XML.element", "XML.element-content", "XML.element-having-tag-with", 
                                    "XML.element-name"]}

reservedTokens = reservedOpNames language ++ reservedNames language

partialExpressionParser :: Parsec.Parser (Expression, [Char], Int)
partialExpressionParser = do whiteSpace lexer
                             t <- expressionParser
                             whiteSpace lexer
                             rest <- getInput
                             pos <- getPosition
                             return (t, rest, sourceLine pos - 1)

expressionParser :: Parsec.Parser Expression
expressionParser = do head <- stepParser
                      whiteSpace lexer
                      (do tail <- many1 (try (symbol lexer ";" >> stepParser))
                          return (foldr1 Sequence (head:tail))
                       <|>
                       do tail <- many1 (try (symbol lexer "&" >> stepParser))
                          return (foldr1 Join (head:tail))
                       <|>
                       return head
                       )

stepParser :: Parsec.Parser Expression
stepParser = do head <- termParser
                whiteSpace lexer
                tail <- many (try (char '|' >> whiteSpace lexer >> termParser))
                return (foldr1 Pipe (head:tail))

termParser :: Parsec.Parser Expression
termParser =
   do first <- prefixTermParser
      whiteSpace lexer
      option first (liftM (foldr1 FollowedBy . (first :)) (many1 $ try (symbol lexer ">," >> prefixTermParser))
                    <|>
                    liftM (foldr1 Or . (first :)) (many1 $ try (symbol lexer ">|" >> prefixTermParser))
                    <|>
                    liftM (foldr1 And . (first :)) (many1 $ try (symbol lexer ">&" >> prefixTermParser))
                    <|>
                    liftM (foldr1 ZipWithOr . (first :)) (many1 $ try (symbol lexer "||" >> prefixTermParser))
                    <|>
                    liftM (foldr1 ZipWithAnd . (first :)) (many1 $ try (symbol lexer "&&" >> prefixTermParser))
                    <|>
                    liftM (Between first) (try (symbol lexer "..." >> prefixTermParser))
                    <|>
                    liftM (HavingOnly first) (try (symbol lexer "having-only" >> prefixTermParser))
                    <|>
                    liftM (Having first) (try (symbol lexer "having" >> prefixTermParser))
                   )

prefixTermParser :: Parsec.Parser Expression
prefixTermParser =
   try (symbol lexer ">!" >> liftM Not prefixTermParser)
   <|> try (symbol lexer "prefix" >> liftM Prefix prefixTermParser)
   <|> try (symbol lexer "suffix" >> liftM Suffix prefixTermParser)
   <|> try (symbol lexer "prepend" >> liftM Prepend prefixTermParser)
   <|> try (symbol lexer "append" >> liftM Append prefixTermParser)
   <|> try (symbol lexer "substitute" >> liftM Substitute prefixTermParser)
   <|> try (symbol lexer "first" >> liftM First prefixTermParser)
   <|> try (symbol lexer "last" >> liftM Last prefixTermParser)
   <|> try (symbol lexer "start-of" >> liftM StartOf prefixTermParser)
   <|> try (symbol lexer "end-of" >> liftM EndOf prefixTermParser)
   <|> try (symbol lexer "select" >> liftM Select prefixTermParser)
   <|> try (symbol lexer "XML.element-having-tag-with" >> liftM XMLElementHavingTag prefixTermParser)
   <|> primaryParser

primaryParser :: Parsec.Parser Expression
primaryParser =
   try (do char '('
           whiteSpace lexer
           expression <- expressionParser
           whiteSpace lexer
           char ')'
           return expression)
   <|> try (symbol lexer "exit" >> return Exit)
   <|> try (nativeSourceParser "cat")
   <|> try (nativeSourceParser "ls")
   <|> try (do symbol lexer "echo"
               string <- nativeCommand True
               return (ProduceFrom string))
   <|> try (symbol lexer "stdin" >> return StdInProducer)
   <|> try (do symbol lexer ">>"
               file <- parameterParser True
               return (FileAppend file))
   <|> try (do symbol lexer ">"
               file <- parameterParser True
               return (FileConsumer file))
   <|> try (symbol lexer "suppress" >> return Suppress)
   <|> try (do symbol lexer "error"
               message <- (try (parameterParser True) <|> return "Error sink reached!")
               return (ErrorConsumer message))
   <|> try (symbol lexer "concatenate" >> return Concatenate)
   <|> try (symbol lexer "count" >> return Count)
   <|> try (symbol lexer "digits" >> return DigitSplitter)
   <|> try (symbol lexer "everything" >> return EverythingSplitter)
   <|> try (symbol lexer "execute" >> return ExecuteTransducer)
   <|> try (symbol lexer "group" >> return Group)
   <|> try (symbol lexer "id" >> return IdentityTransducer)
   <|> try (symbol lexer "letters" >> return LetterSplitter)
   <|> try (symbol lexer "line" >> return LineSplitter)
   <|> try (symbol lexer "marked" >> return MarkedSplitter)
   <|> try (symbol lexer "nothing" >> return NothingSplitter)
   <|> try (symbol lexer "one" >> return OneSplitter)
   <|> try (symbol lexer "show" >> return ShowTransducer)
   <|> try (symbol lexer "uppercase" >> return Uppercase)
   <|> try (symbol lexer "unparse" >> return Unparse)
   <|> try (symbol lexer "whitespace" >> return WhitespaceSplitter)
   <|> try (symbol lexer "XML.attribute-name" >> return XMLAttributeName)
   <|> try (symbol lexer "XML.attribute-value" >> return XMLAttributeValue)
   <|> try (symbol lexer "XML.attribute" >> return XMLAttribute)
   <|> try (symbol lexer "XML.element-content" >> return XMLElementContent)
   <|> try (symbol lexer "XML.element-name" >> return XMLElementName)
   <|> try (symbol lexer "XML.element" >> return XMLElement)
   <|> try (symbol lexer "XML.parse" >> return XMLTokenParser)
   <|> try (do symbol lexer "substring"
               part <- parameterParser True
               return (SubstringSplitter part))
   <|> try (do symbol lexer "if"
               splitter <- expressionParser
               whiteSpace lexer
               symbol lexer "then"
               true <- expressionParser
               false <- (try (symbol lexer "else" >> expressionParser)
                         <|> return Suppress)
               symbol lexer "end"
               option "" (symbol lexer "if")
               return (If splitter true false))
   <|> try (do symbol lexer "nested"
               core <- expressionParser
               whiteSpace lexer
               symbol lexer "in"
               shell <- expressionParser
               whiteSpace lexer
               symbol lexer "end"
               option "" (symbol lexer "nested")
               return (Nested core shell))
   <|> try (do symbol lexer "while"
               test <- expressionParser
               whiteSpace lexer
               symbol lexer "do"
               body <- expressionParser
               whiteSpace lexer
               symbol lexer "end"
               option "" (symbol lexer "while")
               return (While test body))
   <|> try (do symbol lexer "foreach"
               splitter <- expressionParser
               whiteSpace lexer
               symbol lexer "then"
               trueBranch <- expressionParser
               whiteSpace lexer
               falseBranch <- (try (symbol lexer "else" >> expressionParser)
                               <|> return IdentityTransducer)
               whiteSpace lexer
               symbol lexer "end"
               option "" (symbol lexer "foreach")
               return (ForEach splitter trueBranch falseBranch))
   <|> liftM NativeCommand (nativeCommand False)

nativeSourceParser :: String -> Parsec.Parser Expression
nativeSourceParser command = do symbol lexer command
                                params <- nativeCommand False
                                return (NativeCommand (command ++ " " ++ params))

nativeCommand :: Bool -> Parsec.Parser String
nativeCommand normalize = do parts <- try (lexeme lexer (parameterParser normalize)
                                           `manyTill`
                                           ((eof >> return "")
                                            <|> lookAhead (choice (map (try . symbol lexer) reservedTokens))))
                             return (concat (intersperse " " parts))
   where manyTill :: GenParser tok st a -> GenParser tok st end -> GenParser tok st [a]
         manyTill p end      = scan
            where scan  = do{ end; return [] }
                            <|>
                          do{ x <- p; xs <- scan; return (x:xs) }
                            <|>
                          return []

parameterParser :: Bool -> Parsec.Parser String
parameterParser normalize = do chars <- many (noneOf " \t\n'\"`\\()[]{}<>|&;")
                               (do try (string "\\n")
                                   rest <- option "" (parameterParser normalize)
                                   return (chars ++ '\n' : rest)
                                <|>
                                do try (string "\\t")
                                   rest <- option "" (parameterParser normalize)
                                   return (chars ++ '\t' : rest)
                                <|>
                                do next <- escape
                                   rest <- option "" (parameterParser normalize)
                                   return (chars ++ next : rest)
                                <|>
                                do quote <- oneOf "'\"`"
                                   string <- many (try (noneOf (quote : "\\")) <|> escape)
                                   char quote
                                   rest <- option "" (parameterParser normalize)
                                   return (chars ++ (if normalize then string else quote : (string ++ [quote])) ++ rest)
                                <|>
                                do try (char '(')
                                   whiteSpace lexer
                                   inside <- nativeCommand normalize
                                   char ')'
                                   rest <- option "" (parameterParser normalize)
                                   return (chars ++ '(' : inside ++ ')' : rest)
                                <|>
                                do try (char '[')
                                   whiteSpace lexer
                                   inside <- nativeCommand normalize
                                   char ']'
                                   rest <- parameterParser normalize
                                   return (chars ++ '[' : inside ++ ']' : rest)
                                <|>
                                do try (char '{')
                                   whiteSpace lexer
                                   inside <- nativeCommand normalize
                                   char '}'
                                   rest <- option "" (parameterParser normalize)
                                   return (chars ++ '{' : inside ++ '}' : rest)
                                <|>
                                do when (null chars) parserZero
                                   return chars)

escape :: Parsec.Parser Char
escape = do char '\\'
            escaped <- anyChar
            return (case escaped of 'n' -> '\n'
                                    'r' -> '\r'
                                    't' -> '\t'
                                    _ -> escaped)

stringLexemeParser :: Parsec.Parser String
stringLexemeParser = do terminator <- oneOf "'\"`"
                        content <- many (try (noneOf ['\\', terminator]
                                              <|> (string "\\t" >> return '\t')
                                              <|> (string "\\n" >> return '\n')
                                              <|> (char '\\' >> anyChar)))
                        char terminator
                        return (terminator : (content ++ [terminator]))
