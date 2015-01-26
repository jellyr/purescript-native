-----------------------------------------------------------------------------
--
-- Module      :  Language.PureScript.CodeGen.Cpp
-- Copyright   :  (c) _ 2013
-- License     :  MIT
--
-- Maintainer  :  _
-- Stability   :  experimental
-- Portability :
--
-- |
-- This module generates code in the simplified Javascript intermediate representation from Purescript code
--
-----------------------------------------------------------------------------
{-# LANGUAGE PatternGuards #-}

module Language.PureScript.CodeGen.Cpp where

import Data.List (elemIndices, intercalate, nub, sort)
import Data.Char (isAlphaNum, toUpper)

import Control.Applicative

import Language.PureScript.CodeGen.JS.AST as AST
import Language.PureScript.CodeGen.JS.Common as Common
import Language.PureScript.CoreFn
import Language.PureScript.Names
import qualified Language.PureScript.Constants as C
import qualified Language.PureScript.Types as T

import Debug.Trace

headerPreamble :: [JS]
headerPreamble =
  [ JSRaw "// Standard includes"
  , JSRaw "//"
  , JSRaw "#include <functional>"
  , JSRaw "#include <memory>"
  , JSRaw "#include <vector>"
  , JSRaw "#include <string>"
  , JSRaw "#include <iostream>"
  , JSRaw " "
  , JSRaw "// Type support"
  , JSRaw " "
  , JSRaw "template <typename T, typename Enable = void>"
  , JSRaw "struct ADT;"
  , JSRaw " "
  , JSRaw "template <typename T>"
  , JSRaw "struct ADT <T, typename std::enable_if<std::is_fundamental<T>::value>::type> {"
  , JSRaw "  using type = T;"
  , JSRaw "  template <typename... ArgTypes>"
  , JSRaw "  constexpr static auto make(ArgTypes... args) -> type {"
  , JSRaw "    return T(args...);"
  , JSRaw "  }"
  , JSRaw "};"
  , JSRaw " "
  , JSRaw "template <typename T>"
  , JSRaw "struct ADT <T, typename std::enable_if<!std::is_fundamental<T>::value>::type> {"
  , JSRaw "  using type = std::shared_ptr<T>;"
  , JSRaw "  template <typename... ArgTypes>"
  , JSRaw "  constexpr static auto make(ArgTypes... args) -> type {"
  , JSRaw "    return std::make_shared<T>(args...);"
  , JSRaw "  }"
  , JSRaw "};"
  , JSRaw " "
  , JSRaw "// Type aliases"
  , JSRaw "//"
  , JSRaw "template <typename T, typename U> using fn = std::function<U(T)>;"
  , JSRaw "template <typename T> using data = typename ADT<T>::type;"
  , JSRaw "template <typename T> using list = std::vector<T>;"
  , JSRaw "using string = std::string;"
  , JSRaw " "
  , JSRaw "// Function aliases"
  , JSRaw " "
  , JSRaw "template <typename T, typename... ArgTypes>"
  , JSRaw "constexpr auto make_data(ArgTypes... args) -> typename ADT<T>::type {"
  , JSRaw "  return ADT<T>::make(args...);"
  , JSRaw "}"
  , JSRaw " "
  , JSRaw "template <typename T, typename U>"
  , JSRaw "constexpr auto cast(const std::shared_ptr<U>& a) -> T {"
  , JSRaw "  return *(std::dynamic_pointer_cast<T>(a));"
  , JSRaw "}"
  , JSRaw " "
  , JSRaw "template <typename T, typename U>"
  , JSRaw "constexpr auto instanceof(const std::shared_ptr<U>& a) -> std::shared_ptr<T> {"
  , JSRaw "  return std::dynamic_pointer_cast<T>(a);"
  , JSRaw "}"
  , JSRaw " "
  ]

noOp :: JS
noOp = JSRaw []
-----------------------------------------------------------------------------------------------------------------------
typestr :: ModuleName -> T.Type -> String
typestr _ (T.TypeConstructor (Qualified (Just (ModuleName [ProperName "Prim"])) (ProperName "Number")))  = "long"
typestr _ (T.TypeConstructor (Qualified (Just (ModuleName [ProperName "Prim"])) (ProperName "String")))  = "string"
typestr _ (T.TypeConstructor (Qualified (Just (ModuleName [ProperName "Prim"])) (ProperName "Boolean"))) = "bool"

typestr _ (T.TypeApp
            (T.TypeApp
              (T.TypeConstructor (Qualified (Just (ModuleName [ProperName "Prim"])) (ProperName "Function")))
               T.REmpty) _)
                 = error "Need to supprt func() T"

typestr m (T.TypeApp
            (T.TypeApp
              (T.TypeConstructor (Qualified (Just (ModuleName [ProperName "Prim"])) (ProperName "Function")))
               a) b)
                 = "fn<" ++ typestr m a ++ "," ++ typestr m b ++ ">"

typestr m (T.TypeApp
            (T.TypeConstructor (Qualified (Just (ModuleName [ProperName "Prim"])) (ProperName "Array")))
             a)
               = ("list<" ++ typestr m a ++ ">")

typestr _ (T.TypeApp
            (T.TypeConstructor (Qualified (Just (ModuleName [ProperName "Prim"])) (ProperName "Object")))
             T.REmpty)
               = ("std::nullptr_t")

typestr m (T.TypeApp
            (T.TypeConstructor (Qualified (Just (ModuleName [ProperName "Prim"])) (ProperName "Object")))
             a)
               = ("struct{" ++ typestr m a ++ "}")

typestr m app@(T.TypeApp a b)
  | (T.TypeConstructor _) <- a, [t] <- dataCon m app = asDataTy t
  | (T.TypeConstructor _) <- a, (t:ts) <- dataCon m app = asDataTy $ t ++ '<' : intercalate "," ts ++ ">"
  | (T.TypeConstructor _) <- b, [t] <- dataCon m app = asDataTy t
  | (T.TypeConstructor _) <- b, (t:ts) <- dataCon m app = asDataTy $ t ++ '<' : intercalate "," ts ++ ">"

typestr m (T.TypeApp a b) = "fn<" ++ typestr m a ++ "," ++ typestr m b ++ ">"
typestr m (T.ForAll _ ty _) = typestr m ty
typestr _ (T.Skolem (n:ns) _ _) = '#' : toUpper n : ns
typestr _ (T.TypeVar name) = name
typestr m a@(T.TypeConstructor _) = asDataTy $ qualDataTypeName m a
typestr m (T.ConstrainedType _ ty) = typestr m ty
typestr _ T.REmpty = []
typestr m b = error "Unknown type: " ++ show b
-----------------------------------------------------------------------------------------------------------------------
fnArgStr :: ModuleName -> Maybe T.Type -> String
fnArgStr m (Just ((T.TypeApp
                    (T.TypeApp
                      (T.TypeConstructor (Qualified (Just (ModuleName [ProperName "Prim"])) (ProperName "Function")))
                       a) _)))
                         = typestr m a
fnArgStr m (Just (T.ForAll _ ty _)) = fnArgStr m (Just ty)
fnArgStr _ _ = []
-----------------------------------------------------------------------------------------------------------------------
fnRetStr :: ModuleName -> Maybe T.Type -> String
fnRetStr m (Just ((T.TypeApp
                    (T.TypeApp
                      (T.TypeConstructor (Qualified (Just (ModuleName [ProperName "Prim"])) (ProperName "Function")))
                       _) b)))
                         = typestr m b
fnRetStr m (Just (T.ForAll _ ty _)) = fnRetStr m (Just ty)
fnRetStr _ _ = []
-----------------------------------------------------------------------------------------------------------------------
dataCon :: ModuleName -> T.Type -> [String]
dataCon m (T.TypeApp a b) = (dataCon m a) ++ (dataCon m b)
dataCon m a@(T.TypeConstructor (Qualified (Just (ModuleName [ProperName "Prim"])) _)) = [typestr m a]
dataCon m a@(T.TypeConstructor _) = [qualDataTypeName m a]
dataCon m a = [typestr m a]
-----------------------------------------------------------------------------------------------------------------------
qualDataTypeName :: ModuleName -> T.Type -> String
qualDataTypeName m (T.TypeConstructor typ) = intercalate "::" . words $ brk tname
  where
    tname = qualifiedToStr m (Ident . runProperName) typ
    brk = map (\c -> if c=='.' then ' ' else c)
qualDataTypeName _ _ = []
-----------------------------------------------------------------------------------------------------------------------
fnName :: Maybe String -> String -> Maybe String
fnName Nothing name = Just name
fnName (Just t) name = Just (t ++ ' ' : (identToJs $ Ident name))
-----------------------------------------------------------------------------------------------------------------------
templTypes :: String -> String
templTypes s
  | ('#' `elem` s) = intercalate ", " (("typename "++) <$> templParms s) ++ "|"
templTypes _ = []
-----------------------------------------------------------------------------------------------------------------------
templTypes' :: ModuleName -> Maybe T.Type -> String
templTypes' m (Just t)
  | s <- typestr m t = templTypes s
templTypes' _ _ = ""
-----------------------------------------------------------------------------------------------------------------------
stripImpls :: JS -> JS
stripImpls (JSNamespace name bs) = JSNamespace name (map stripImpls bs)
stripImpls (JSComment c e) = JSComment c (stripImpls e)
stripImpls (JSVariableIntroduction var (Just (JSFunction (Just name) [arg] ret@(JSBlock [JSReturn (JSApp _ [JSVar arg'])]))))
  | ((last $ words arg) == arg') = JSVariableIntroduction var (Just (JSFunction (Just $ name ++ " inline") [arg] ret))
stripImpls imp@(JSVariableIntroduction _ (Just (JSFunction (Just name) _ _))) | '|' `elem` name = imp
stripImpls (JSVariableIntroduction var (Just expr)) = JSVariableIntroduction var (Just $ stripImpls expr)
stripImpls (JSFunction fn args _) = JSFunction fn args noOp
stripImpls dat@(JSData _ _ _ _) = dat
stripImpls _ = noOp
-----------------------------------------------------------------------------------------------------------------------
stripDecls :: JS -> JS
stripDecls (JSNamespace name bs) = JSNamespace name (map stripDecls bs)
stripDecls (JSComment c e) = JSComment c (stripDecls e)
stripDecls imp@(JSVariableIntroduction var (Just (JSFunction (Just name) [arg] (JSBlock [JSReturn (JSApp _ [JSVar arg'])]))))
  | ((last $ words arg) == arg') = noOp
stripDecls (JSVariableIntroduction _ (Just (JSFunction (Just name) _ _))) | '|' `elem` name = noOp
stripDecls (JSVariableIntroduction var (Just expr)) = JSVariableIntroduction var (Just $ stripDecls expr)
stripDecls (JSData _ _ _ _) = noOp
stripDecls js = js
-----------------------------------------------------------------------------------------------------------------------
dataTypes :: [Bind Ann] -> [JS]
dataTypes = map (JSVar . mkClass) . nub . filter (not . null) . map dataType
  where
    mkClass :: String -> String
    mkClass s = templateDecl ++ "struct " ++ rmType s ++ " { virtual ~" ++ rmType s ++ "(){} };"
      where
        templateDecl
          | t@('[':_:_:_) <- drop 1 $ getType s = "template " ++ '<' : intercalate ", " (("typename " ++) <$> read t) ++ "> "
          | otherwise = []
-----------------------------------------------------------------------------------------------------------------------
dataType :: Bind Ann -> String
dataType (NonRec _ (Constructor (_, _, _, Just IsNewtype) _ _ _)) = []
dataType (NonRec _ (Constructor (_, _, _, _) name _ _)) = runProperName name
dataType _ = []
-----------------------------------------------------------------------------------------------------------------------
getAppSpecType :: ModuleName -> Expr Ann -> Int -> String
getAppSpecType m e l
    | (App (_, _, Just dty, _) _ _) <- e,
      (_:ts) <- dataCon m dty,
      ty@(_:_) <- drop l ts                 = '<' : intercalate "," ty ++ ">"
    | otherwise = []
-----------------------------------------------------------------------------------------------------------------------
qualifiedToStr :: ModuleName -> (a -> Ident) -> Qualified a -> String
qualifiedToStr _ f (Qualified (Just (ModuleName [ProperName mn])) a) | mn == C.prim = runIdent $ f a
qualifiedToStr m f (Qualified (Just m') a) | m /= m' = moduleNameToJs m' ++ "::" ++ identToJs (f a)
qualifiedToStr _ f (Qualified _ a) = identToJs (f a)
-----------------------------------------------------------------------------------------------------------------------
asDataTy :: String -> String
asDataTy t = "data<" ++ t ++ ">"
-----------------------------------------------------------------------------------------------------------------------
mkData :: String -> String
mkData t = "make_data<" ++ t ++ ">"
-----------------------------------------------------------------------------------------------------------------------
dataCtorName :: String
dataCtorName = "ctor"
-----------------------------------------------------------------------------------------------------------------------
mkDataFn :: String -> String
mkDataFn t = t ++ ':':':':dataCtorName
-----------------------------------------------------------------------------------------------------------------------
mkUnique :: String -> String
mkUnique s = '_' : s ++ "_"

mkUnique' :: Ident -> Ident
mkUnique' (Ident s) = Ident $ mkUnique s
mkUnique' ident = ident
-----------------------------------------------------------------------------------------------------------------------
addType :: String -> String
addType t = '@' : t
-----------------------------------------------------------------------------------------------------------------------
getType :: String -> String
getType = dropWhile (/='@')
-----------------------------------------------------------------------------------------------------------------------
getSpecialization :: String -> String
getSpecialization s = case spec of
                        ('<':ss) -> '<' : take (length ss - 2) ss ++ ">"
                        _ -> []
  where
    spec = dropWhile (/='<') . drop 1 $ dropWhile (/='<') s
-----------------------------------------------------------------------------------------------------------------------
rmType :: String -> String
rmType = takeWhile (/='@')
-----------------------------------------------------------------------------------------------------------------------
fromAngles :: String -> Int -> String
fromAngles [] _ = []
fromAngles _ 0 = []
fromAngles (x@'<':xs) n = x : fromAngles xs (n+1)
fromAngles (x@'>':xs) n = x : fromAngles xs (n-1)
fromAngles (x:xs)     n = x : fromAngles xs n
-----------------------------------------------------------------------------------------------------------------------
afterAngles :: String -> Int -> String
afterAngles [] _ = []
afterAngles xs 0 = xs
afterAngles ('<':xs) n = afterAngles xs (n+1)
afterAngles ('>':xs) n = afterAngles xs (n-1)
afterAngles (_:xs)   n = afterAngles xs n
-----------------------------------------------------------------------------------------------------------------------
getArg :: String -> String
getArg ('f':'n':'<':xs) = "fn<" ++ fromAngles xs 1
getArg xs = takeWhile (/=',') xs
-----------------------------------------------------------------------------------------------------------------------
getRet :: String -> String
getRet ('f':'n':'<':xs) = drop 1 $ afterAngles xs 1
getRet xs = drop 1 $ dropWhile (/=',') xs
-----------------------------------------------------------------------------------------------------------------------
templParms :: String -> [String]
templParms s = nub . sort $ (takeWhile isAlphaNum . flip drop s) <$> (map (+1) . elemIndices '#' $ s)

extractTypes :: String -> [String]
extractTypes = words . extractTypes'

extractTypes' :: String -> String
extractTypes' [] = []
extractTypes' ('f':'n':'<':xs) = ' ' : extractTypes' xs
extractTypes' (x:xs) | not (isAlphaNum x) = ' ' : extractTypes' xs
extractTypes' (x:xs) = x : extractTypes' xs
