-- |
-- Module      :  Cryptol.ModuleSystem.Interface
-- Copyright   :  (c) 2013-2016 Galois, Inc.
-- License     :  BSD3
-- Maintainer  :  cryptol@galois.com
-- Stability   :  provisional
-- Portability :  portable

{-# LANGUAGE CPP #-}
{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE PatternGuards #-}
{-# LANGUAGE RecordWildCards #-}
module Cryptol.ModuleSystem.Interface (
    Iface
  , IfaceG(..)
  , IfaceDecls(..)
  , IfaceTySyn, ifTySynName
  , IfaceNewtype
  , IfaceDecl(..)
  , IfaceParams(..)
  , IfaceModParam(..)

  , emptyIface
  , ifacePrimMap
  , noIfaceParams
  , isEmptyIfaceParams
  , ifaceIsFunctor
  , flatPublicIface
  , flatPublicDecls
  , filterIfaceDecls
  , ifaceDeclsNames
  ) where

import           Data.Set(Set)
import qualified Data.Set as Set
import           Data.Map(Map)
import qualified Data.Map as Map
import           Data.Semigroup
import           Data.Text (Text)

import GHC.Generics (Generic)
import Control.DeepSeq

import Prelude ()
import Prelude.Compat

import Cryptol.ModuleSystem.Name
import Cryptol.Utils.Ident (ModName,Ident)
import Cryptol.Utils.Panic(panic)
import Cryptol.Utils.Fixity(Fixity)
import Cryptol.Parser.AST(Pragma)
import Cryptol.Parser.Position(Located,Range)
import Cryptol.TypeCheck.Type


-- | The resulting interface generated by a module that has been typechecked.
data IfaceG mname = Iface
  { ifModName   :: !mname       -- ^ Module name
  , ifPublic    :: IfaceDecls   -- ^ Exported definitions
  , ifPrivate   :: IfaceDecls   -- ^ Private defintiions
  , ifParams    :: IfaceParams  -- ^ Uninterpreted constants (aka module params)
  } deriving (Show, Generic, NFData)

ifaceIsFunctor :: IfaceG mname -> Bool
ifaceIsFunctor = not . isEmptyIfaceParams . ifParams

-- | The public declarations in all modules, including nested
-- The modules field contains public functors
-- Assumes that we are not a functor.
flatPublicIface :: IfaceG mname -> IfaceDecls
flatPublicIface iface = flatPublicDecls (ifPublic iface)


flatPublicDecls :: IfaceDecls -> IfaceDecls
flatPublicDecls ifs = mconcat ( ifs { ifModules = fun }
                              : map flatPublicIface (Map.elems nofun)
                              )

  where
  (fun,nofun) = Map.partition ifaceIsFunctor (ifModules ifs)


type Iface = IfaceG ModName

emptyIface :: mname -> IfaceG mname
emptyIface nm = Iface
  { ifModName = nm
  , ifPublic  = mempty
  , ifPrivate = mempty
  , ifParams  = noIfaceParams
  }

data IfaceParams = IfaceParams
  { ifParamTypes       :: Map.Map Name ModTParam
  , ifParamConstraints :: [Located Prop] -- ^ Constraints on param. types
  , ifParamFuns        :: Map.Map Name ModVParam
  , ifParamDoc         :: !(Maybe Text)
  } deriving (Show, Generic, NFData)

noIfaceParams :: IfaceParams
noIfaceParams = IfaceParams
  { ifParamTypes = Map.empty
  , ifParamConstraints = []
  , ifParamFuns = Map.empty
  , ifParamDoc = Nothing
  }

isEmptyIfaceParams :: IfaceParams -> Bool
isEmptyIfaceParams IfaceParams { .. } =
  Map.null ifParamTypes && null ifParamConstraints && Map.null ifParamFuns


data IfaceModParam = IfaceModParam
  { ifModParamName      :: Ident
  , ifModParamRange     :: Range
  , ifModParamSig       :: Name
  , ifModParamInstance  :: Map Name Name -- ^ Maps param names to names in sig.
  }

data IfaceDecls = IfaceDecls
  { ifTySyns        :: Map.Map Name IfaceTySyn
  , ifNewtypes      :: Map.Map Name IfaceNewtype
  , ifAbstractTypes :: Map.Map Name IfaceAbstractType
  , ifDecls         :: Map.Map Name IfaceDecl
  , ifModules       :: !(Map.Map Name (IfaceG Name))
  , ifSignatures    :: !(Map.Map Name IfaceParams)
  } deriving (Show, Generic, NFData)

filterIfaceDecls :: (Name -> Bool) -> IfaceDecls -> IfaceDecls
filterIfaceDecls p ifs = IfaceDecls
  { ifTySyns        = filterMap (ifTySyns ifs)
  , ifNewtypes      = filterMap (ifNewtypes ifs)
  , ifAbstractTypes = filterMap (ifAbstractTypes ifs)
  , ifDecls         = filterMap (ifDecls ifs)
  , ifModules       = filterMap (ifModules ifs)
  , ifSignatures    = filterMap (ifSignatures ifs)
  }
  where
  filterMap :: Map.Map Name a -> Map.Map Name a
  filterMap = Map.filterWithKey (\k _ -> p k)

ifaceDeclsNames :: IfaceDecls -> Set Name
ifaceDeclsNames i = Set.unions [ Map.keysSet (ifTySyns i)
                               , Map.keysSet (ifNewtypes i)
                               , Map.keysSet (ifAbstractTypes i)
                               , Map.keysSet (ifDecls i)
                               , Map.keysSet (ifModules i)
                               , Map.keysSet (ifSignatures i)
                               ]


instance Semigroup IfaceDecls where
  l <> r = IfaceDecls
    { ifTySyns   = Map.union (ifTySyns l)   (ifTySyns r)
    , ifNewtypes = Map.union (ifNewtypes l) (ifNewtypes r)
    , ifAbstractTypes = Map.union (ifAbstractTypes l) (ifAbstractTypes r)
    , ifDecls    = Map.union (ifDecls l)    (ifDecls r)
    , ifModules  = Map.union (ifModules l)  (ifModules r)
    , ifSignatures = ifSignatures l <> ifSignatures r
    }

instance Monoid IfaceDecls where
  mempty      = IfaceDecls Map.empty Map.empty Map.empty Map.empty Map.empty
                           mempty
  mappend l r = l <> r
  mconcat ds  = IfaceDecls
    { ifTySyns   = Map.unions (map ifTySyns   ds)
    , ifNewtypes = Map.unions (map ifNewtypes ds)
    , ifAbstractTypes = Map.unions (map ifAbstractTypes ds)
    , ifDecls    = Map.unions (map ifDecls    ds)
    , ifModules  = Map.unions (map ifModules ds)
    , ifSignatures = Map.unions (map ifSignatures ds)
    }

type IfaceTySyn = TySyn

ifTySynName :: TySyn -> Name
ifTySynName = tsName

type IfaceNewtype = Newtype
type IfaceAbstractType = AbstractType

data IfaceDecl = IfaceDecl
  { ifDeclName    :: !Name          -- ^ Name of thing
  , ifDeclSig     :: Schema         -- ^ Type
  , ifDeclPragmas :: [Pragma]       -- ^ Pragmas
  , ifDeclInfix   :: Bool           -- ^ Is this an infix thing
  , ifDeclFixity  :: Maybe Fixity   -- ^ Fixity information
  , ifDeclDoc     :: Maybe Text     -- ^ Documentation
  } deriving (Show, Generic, NFData)


-- | Produce a PrimMap from an interface.
--
-- NOTE: the map will expose /both/ public and private names.
ifacePrimMap :: Iface -> PrimMap
ifacePrimMap Iface { .. } =
  PrimMap { primDecls = merge primDecls
          , primTypes = merge primTypes }
  where
  merge f = Map.union (f public) (f private)

  public  = ifaceDeclsPrimMap ifPublic
  private = ifaceDeclsPrimMap ifPrivate

ifaceDeclsPrimMap :: IfaceDecls -> PrimMap
ifaceDeclsPrimMap IfaceDecls { .. } =
  PrimMap { primDecls = Map.fromList (newtypes ++ exprs)
          , primTypes = Map.fromList (newtypes ++ types)
          }
  where
  entry n = case asPrim n of
              Just pid -> (pid,n)
              Nothing ->
                panic "ifaceDeclsPrimMap"
                          [ "Top level name not declared in a module?"
                          , show n ]

  exprs    = map entry (Map.keys ifDecls)
  newtypes = map entry (Map.keys ifNewtypes)
  types    = map entry (Map.keys ifTySyns)
