-- |
-- Module      :  Cryptol.ModuleSystem.Renamer
-- Copyright   :  (c) 2013-2016 Galois, Inc.
-- License     :  BSD3
-- Maintainer  :  cryptol@galois.com
-- Stability   :  provisional
-- Portability :  portable

{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE MultiWayIf #-}
{-# LANGUAGE PatternGuards #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE ViewPatterns #-}
{-# LANGUAGE OverloadedStrings #-}
module Cryptol.ModuleSystem.Renamer (
    NamingEnv(), shadowing
  , BindsNames(..), InModule(..), namingEnv'
  , checkNamingEnv
  , shadowNames
  , Rename(..), runRenamer, RenameM()
  , RenamerError(..)
  , RenamerWarning(..)
  , renameVar
  , renameType
  , renameModule
  ) where

import Cryptol.ModuleSystem.Name
import Cryptol.ModuleSystem.NamingEnv
import Cryptol.ModuleSystem.Exports
import Cryptol.Parser.AST
import Cryptol.Parser.Names (namesE, namesB)
import Cryptol.Parser.Position
import Cryptol.Parser.NoPat (splitSimpleP)
import Cryptol.Parser.Selector(ppNestedSels,selName)
import Cryptol.Utils.Panic (panic)
import Cryptol.Utils.PP
import Cryptol.Utils.RecordMap
import Cryptol.Utils.Ident (packIdent)

import Data.List(find)
import qualified Data.Foldable as F
import           Data.Maybe (maybeToList, fromMaybe)
import           Data.Map.Strict ( Map )
import qualified Data.Map.Strict as Map
import qualified Data.Sequence as Seq
import qualified Data.Semigroup as S
import           Data.Set (Set)
import qualified Data.Set as Set
import           MonadLib hiding (mapM, mapM_)

import GHC.Generics (Generic)
import Control.DeepSeq

import Prelude ()
import Prelude.Compat

import Debug.Trace (trace)

-- Errors ----------------------------------------------------------------------

data RenamerError
  = MultipleSyms (Located PName) [Name] NameDisp
    -- ^ Multiple imported symbols contain this name

  | UnboundExpr (Located PName) NameDisp
    -- ^ Expression name is not bound to any definition

  | UnboundType (Located PName) NameDisp
    -- ^ Type name is not bound to any definition

  | OverlappingSyms [Name] NameDisp
    -- ^ An environment has produced multiple overlapping symbols

  | ExpectedValue (Located PName) NameDisp
    -- ^ When a value is expected from the naming environment, but one or more
    -- types exist instead.

  | ExpectedType (Located PName) NameDisp
    -- ^ When a type is missing from the naming environment, but one or more
    -- values exist with the same name.

  | FixityError (Located Name) Fixity (Located Name) Fixity NameDisp
    -- ^ When the fixity of two operators conflict

  | InvalidConstraint (Type PName) NameDisp
    -- ^ When it's not possible to produce a Prop from a Type.

  | MalformedBuiltin (Type PName) PName NameDisp
    -- ^ When a builtin type/type-function is used incorrectly.

  | BoundReservedType PName (Maybe Range) Doc NameDisp
    -- ^ When a builtin type is named in a binder.

  | OverlappingRecordUpdate (Located [Selector]) (Located [Selector]) NameDisp
    -- ^ When record updates overlap (e.g., @{ r | x = e1, x.y = e2 }@)
    deriving (Show, Generic, NFData)

instance PP RenamerError where
  ppPrec _ e = case e of

    MultipleSyms lqn qns disp -> fixNameDisp disp $
      hang (text "[error] at" <+> pp (srcRange lqn))
         4 $ (text "Multiple definitions for symbol:" <+> pp (thing lqn))
          $$ vcat (map ppLocName qns)

    UnboundExpr lqn disp -> fixNameDisp disp $
      hang (text "[error] at" <+> pp (srcRange lqn))
         4 (text "Value not in scope:" <+> pp (thing lqn))

    UnboundType lqn disp -> fixNameDisp disp $
      hang (text "[error] at" <+> pp (srcRange lqn))
         4 (text "Type not in scope:" <+> pp (thing lqn))

    OverlappingSyms qns disp -> fixNameDisp disp $
      hang (text "[error]")
         4 $ text "Overlapping symbols defined:"
          $$ vcat (map ppLocName qns)

    ExpectedValue lqn disp -> fixNameDisp disp $
      hang (text "[error] at" <+> pp (srcRange lqn))
         4 (fsep [ text "Expected a value named", quotes (pp (thing lqn))
                 , text "but found a type instead"
                 , text "Did you mean `(" <.> pp (thing lqn) <.> text")?" ])

    ExpectedType lqn disp -> fixNameDisp disp $
      hang (text "[error] at" <+> pp (srcRange lqn))
         4 (fsep [ text "Expected a type named", quotes (pp (thing lqn))
                 , text "but found a value instead" ])

    FixityError o1 f1 o2 f2 disp -> fixNameDisp disp $
      hang (text "[error] at" <+> pp (srcRange o1) <+> text "and" <+> pp (srcRange o2))
         4 (fsep [ text "The fixities of"
                 , nest 2 $ vcat
                   [ "•" <+> pp (thing o1) <+> parens (pp f1)
                   , "•" <+> pp (thing o2) <+> parens (pp f2) ]
                 , text "are not compatible."
                 , text "You may use explicit parentheses to disambiguate." ])

    InvalidConstraint ty disp -> fixNameDisp disp $
      hang (text "[error]" <+> maybe empty (\r -> text "at" <+> pp r) (getLoc ty))
         4 (fsep [ pp ty, text "is not a valid constraint" ])

    MalformedBuiltin ty pn disp -> fixNameDisp disp $
      hang (text "[error]" <+> maybe empty (\r -> text "at" <+> pp r) (getLoc ty))
         4 (fsep [ text "invalid use of built-in type", pp pn
                 , text "in type", pp ty ])

    BoundReservedType n loc src disp -> fixNameDisp disp $
      hang (text "[error]" <+> maybe empty (\r -> text "at" <+> pp r) loc)
         4 (fsep [ text "built-in type", quotes (pp n), text "shadowed in", src ])

    OverlappingRecordUpdate xs ys disp -> fixNameDisp disp $
      hang "[error] Overlapping record updates:"
         4 (vcat [ ppLab xs, ppLab ys ])
      where
      ppLab as = ppNestedSels (thing as) <+> "at" <+> pp (srcRange as)

-- Warnings --------------------------------------------------------------------

data RenamerWarning
  = SymbolShadowed Name [Name] NameDisp

  | UnusedName Name NameDisp
    deriving (Show, Generic, NFData)

instance PP RenamerWarning where
  ppPrec _ (SymbolShadowed new originals disp) = fixNameDisp disp $
    hang (text "[warning] at" <+> loc)
       4 $ fsep [ text "This binding for" <+> backticks sym
                , text "shadows the existing binding" <.> plural <+>
                  text "at" ]
        $$ vcat (map (pp . nameLoc) originals)

    where
    plural | length originals > 1 = char 's'
           | otherwise            = empty

    loc = pp (nameLoc new)
    sym = pp new

  ppPrec _ (UnusedName x disp) = fixNameDisp disp $
    hang (text "[warning] at" <+> pp (nameLoc x))
       4 (text "Unused name:" <+> pp x)


data RenamerWarnings = RenamerWarnings
  { renWarnNameDisp :: !NameDisp
  , renWarnShadow   :: Map Name (Set Name)
  , renWarnUnused   :: Set Name
  }

noRenamerWarnings :: RenamerWarnings
noRenamerWarnings = RenamerWarnings
  { renWarnNameDisp = mempty
  , renWarnShadow   = Map.empty
  , renWarnUnused   = Set.empty
  }

addRenamerWarning :: RenamerWarning -> RenamerWarnings -> RenamerWarnings
addRenamerWarning w ws =
  case w of
    SymbolShadowed x xs d ->
      ws { renWarnNameDisp = renWarnNameDisp ws <> d
         , renWarnShadow   = Map.insertWith Set.union x (Set.fromList xs)
                                                        (renWarnShadow ws)
         }
    UnusedName x d ->
      ws { renWarnNameDisp = renWarnNameDisp ws <> d
         , renWarnUnused   = Set.insert x (renWarnUnused ws)
         }

listRenamerWarnings :: RenamerWarnings -> [RenamerWarning]
listRenamerWarnings ws =
  [ mk (UnusedName x) | x      <- Set.toList (renWarnUnused ws) ] ++
  [ mk (SymbolShadowed x (Set.toList xs))
          | (x,xs) <- Map.toList (renWarnShadow ws) ]
  where
  mk f = f (renWarnNameDisp ws)


-- Renaming Monad --------------------------------------------------------------

data RO = RO
  { roLoc   :: Range
  , roMod   :: !ModName
  , roNames :: NamingEnv
  , roDisp  :: !NameDisp
  }

data RW = RW
  { rwWarnings      :: !RenamerWarnings
  , rwErrors        :: !(Seq.Seq RenamerError)
  , rwSupply        :: !Supply
  , rwNameUseCount  :: !(Map Name Int)
    -- ^ How many times did we refer to each name.
    -- Used to generate warnings for unused definitions.
  }



newtype RenameM a = RenameM
  { unRenameM :: ReaderT RO (StateT RW Lift) a }

instance S.Semigroup a => S.Semigroup (RenameM a) where
  {-# INLINE (<>) #-}
  a <> b =
    do x <- a
       y <- b
       return (x S.<> y)

instance (S.Semigroup a, Monoid a) => Monoid (RenameM a) where
  {-# INLINE mempty #-}
  mempty = return mempty

  {-# INLINE mappend #-}
  mappend = (S.<>)

instance Functor RenameM where
  {-# INLINE fmap #-}
  fmap f m      = RenameM (fmap f (unRenameM m))

instance Applicative RenameM where
  {-# INLINE pure #-}
  pure x        = RenameM (pure x)

  {-# INLINE (<*>) #-}
  l <*> r       = RenameM (unRenameM l <*> unRenameM r)

instance Monad RenameM where
  {-# INLINE return #-}
  return x      = RenameM (return x)

  {-# INLINE (>>=) #-}
  m >>= k       = RenameM (unRenameM m >>= unRenameM . k)

instance FreshM RenameM where
  liftSupply f = RenameM $ sets $ \ RW { .. } ->
    let (a,s') = f rwSupply
        rw'    = RW { rwSupply = s', .. }
     in a `seq` rw' `seq` (a, rw')

runRenamer :: Supply -> ModName -> NamingEnv -> RenameM a
           -> (Either [RenamerError] (a,Supply),[RenamerWarning])
runRenamer s ns env m = (res, listRenamerWarnings warns)
  where
  warns = foldr addRenamerWarning (rwWarnings rw)
                                  (warnUnused ns env ro rw)

  (a,rw) = runM (unRenameM m) ro
                              RW { rwErrors   = Seq.empty
                                 , rwWarnings = noRenamerWarnings
                                 , rwSupply   = s
                                 , rwNameUseCount = Map.empty
                                 }

  ro = RO { roLoc = emptyRange
          , roNames = env
          , roMod = ns
          , roDisp = neverQualifyMod ns `mappend` toNameDisp env
          }

  res | Seq.null (rwErrors rw) = Right (a,rwSupply rw)
      | otherwise              = Left (F.toList (rwErrors rw))

-- | Record an error.  XXX: use a better name
record :: (NameDisp -> RenamerError) -> RenameM ()
record f = RenameM $
  do RO { .. } <- ask
     RW { .. } <- get
     set RW { rwErrors = rwErrors Seq.|> f roDisp, .. }

-- | Get the source range for wahtever we are currently renaming.
curLoc :: RenameM Range
curLoc  = RenameM (roLoc `fmap` ask)

-- | Annotate something with the current range.
located :: a -> RenameM (Located a)
located thing =
  do srcRange <- curLoc
     return Located { .. }

-- | Do the given computation using the source code range from `loc` if any.
withLoc :: HasLoc loc => loc -> RenameM a -> RenameM a
withLoc loc m = RenameM $ case getLoc loc of

  Just range -> do
    ro <- ask
    local ro { roLoc = range } (unRenameM m)

  Nothing -> unRenameM m

-- | Retrieve the name of the current module.
getNS :: RenameM ModName
getNS  = RenameM (roMod `fmap` ask)

-- | Shadow the current naming environment with some more names.
shadowNames :: BindsNames env => env -> RenameM a -> RenameM a
shadowNames  = shadowNames' CheckAll

data EnvCheck = CheckAll     -- ^ Check for overlap and shadowing
              | CheckOverlap -- ^ Only check for overlap
              | CheckNone    -- ^ Don't check the environment
                deriving (Eq,Show)

-- | Shadow the current naming environment with some more names.
shadowNames' :: BindsNames env => EnvCheck -> env -> RenameM a -> RenameM a
shadowNames' check names m = do
  do env <- liftSupply (namingEnv' names)
     RenameM $
       do ro  <- ask
          env' <- sets (checkEnv (roDisp ro) check env (roNames ro))
          let ro' = ro { roNames = env' `shadowing` roNames ro }
          local ro' (unRenameM m)

shadowNamesNS :: BindsNames (InModule env) => env -> RenameM a -> RenameM a
shadowNamesNS names m =
  do ns <- getNS
     shadowNames (InModule ns names) m


-- | Generate warnings when the left environment shadows things defined in
-- the right.  Additionally, generate errors when two names overlap in the
-- left environment.
checkEnv :: NameDisp -> EnvCheck -> NamingEnv -> NamingEnv -> RW -> (NamingEnv,RW)
checkEnv disp check l r rw
  | check == CheckNone = (l',rw)
  | otherwise          = (l',rw'')

  where

  l' = l { neExprs = es, neTypes = ts }

  (rw',es)  = Map.mapAccumWithKey (step neExprs) rw  (neExprs l)
  (rw'',ts) = Map.mapAccumWithKey (step neTypes) rw' (neTypes l)

  step prj acc k ns = (acc', [head ns])
    where
    acc' = acc
      { rwWarnings =
          if check == CheckAll
             then case Map.lookup k (prj r) of
                    Nothing -> rwWarnings acc
                    Just os -> addRenamerWarning
                                    (SymbolShadowed (head ns) os disp)
                                    (rwWarnings acc)

             else rwWarnings acc
      , rwErrors   = rwErrors acc Seq.>< containsOverlap disp ns
      }

-- | Check the RHS of a single name rewrite for conflicting sources.
containsOverlap :: NameDisp -> [Name] -> Seq.Seq RenamerError
containsOverlap _    [_] = Seq.empty
containsOverlap _    []  = panic "Renamer" ["Invalid naming environment"]
containsOverlap disp ns  = Seq.singleton (OverlappingSyms ns disp)

-- | Throw errors for any names that overlap in a rewrite environment.
checkNamingEnv :: NamingEnv -> ([RenamerError],[RenamerWarning])
checkNamingEnv env = (F.toList out, [])
  where
  out    = Map.foldr check outTys (neExprs env)
  outTys = Map.foldr check mempty (neTypes env)

  disp   = toNameDisp env

  check ns acc = containsOverlap disp ns Seq.>< acc

recordUse :: Name -> RenameM ()
recordUse x = RenameM $ sets_ $ \rw ->
  rw { rwNameUseCount = Map.insertWith (+) x 1 (rwNameUseCount rw) }


warnUnused :: ModName -> NamingEnv -> RO -> RW -> [RenamerWarning]
warnUnused m0 env ro rw =
  map warn
  $ Map.keys
  $ Map.filterWithKey keep
  $ rwNameUseCount rw
  where
  warn x   = UnusedName x (roDisp ro)
  keep k n = n == 1 && isLocal k
  oldNames = fst (visibleNames env)
  isLocal nm = case nameInfo nm of
                 Declared m sys -> sys == UserName &&
                                   m == m0 && nm `Set.notMember` oldNames
                 Parameter  -> True

-- Renaming --------------------------------------------------------------------

class Rename f where
  rename :: f PName -> RenameM (f Name)

renameModule :: Module PName -> RenameM (NamingEnv,Module Name)
renameModule m =
  do env    <- liftSupply (namingEnv' m)
     -- NOTE: we explicitly hide shadowing errors here, by using shadowNames'
     decls' <-  shadowNames' CheckOverlap env (traverse rename (mDecls m))
     let m1 = m { mDecls = decls' }
         exports = modExports m1
     mapM_ recordUse (eTypes exports)
     return (env,m1)

instance Rename TopDecl where
  rename td     = case td of
    Decl d      -> Decl      <$> traverse rename d
    DPrimType d -> DPrimType <$> traverse rename d
    TDNewtype n -> TDNewtype <$> traverse rename n
    Include n   -> return (Include n)
    DParameterFun f  -> DParameterFun  <$> rename f
    DParameterType f -> DParameterType <$> rename f

    DParameterConstraint d -> DParameterConstraint <$> mapM renameLocated d

renameLocated :: Rename f => Located (f PName) -> RenameM (Located (f Name))
renameLocated x =
  do y <- rename (thing x)
     return x { thing = y }

instance Rename PrimType where
  rename pt =
    do x <- rnLocated renameType (primTName pt)
       let (as,ps) = primTCts pt
       (_,cts) <- renameQual as ps $ \as' ps' -> pure (as',ps')
       pure pt { primTCts = cts, primTName = x }

instance Rename ParameterType where
  rename a =
    do n' <- rnLocated renameType (ptName a)
       return a { ptName = n' }

instance Rename ParameterFun where
  rename a =
    do n'   <- rnLocated renameVar (pfName a)
       sig' <- renameSchema (pfSchema a)
       return a { pfName = n', pfSchema = snd sig' }

rnLocated :: (a -> RenameM b) -> Located a -> RenameM (Located b)
rnLocated f loc = withLoc loc $
  do a' <- f (thing loc)
     return loc { thing = a' }

instance Rename Decl where
  rename d      = case d of
    DSignature ns sig -> DSignature    <$> traverse (rnLocated renameVar) ns
                                       <*> rename sig
    DPragma ns p      -> DPragma       <$> traverse (rnLocated renameVar) ns
                                       <*> pure p
    DBind b           -> DBind         <$> rename b

    -- XXX we probably shouldn't see these at this point...
    DPatBind pat e    -> do (pe,pat') <- renamePat pat
                            shadowNames pe (DPatBind pat' <$> rename e)

    DType syn         -> DType         <$> rename syn
    DProp syn         -> DProp         <$> rename syn
    DLocated d' r     -> withLoc r
                       $ DLocated      <$> rename d'  <*> pure r
    DFixity{}         -> panic "Renamer" ["Unexpected fixity declaration"
                                         , show d]

instance Rename Newtype where
  rename n      = do
    name' <- rnLocated renameType (nName n)
    shadowNames (nParams n) $
      do ps'   <- traverse rename (nParams n)
         body' <- traverse (traverse rename) (nBody n)
         return Newtype { nName   = name'
                        , nParams = ps'
                        , nBody   = body' }

renameVar :: PName -> RenameM Name
renameVar qn = do
  ro <- RenameM ask
  case Map.lookup qn (neExprs (roNames ro)) of
    Just [n]  -> return n
    Just []   -> panic "Renamer" ["Invalid expression renaming environment"]
    Just syms ->
      do n <- located qn
         record (MultipleSyms n syms)
         return (head syms)

    -- This is an unbound value. Record an error and invent a bogus real name
    -- for it.
    Nothing ->
      do n <- located qn

         case Map.lookup qn (neTypes (roNames ro)) of
           -- types existed with the name of the value expected
           Just _ -> record (ExpectedValue n)

           -- the value is just missing
           Nothing -> record (UnboundExpr n)

         mkFakeName qn

-- | Produce a name if one exists. Note that this includes situations where
-- overlap exists, as it's just a query about anything being in scope. In the
-- event that overlap does exist, an error will be recorded.
typeExists :: PName -> RenameM (Maybe Name)
typeExists pn =
  do ro <- RenameM ask
     case Map.lookup pn (neTypes (roNames ro)) of
       Just [n]  -> recordUse n >> return (Just n)
       Just []   -> panic "Renamer" ["Invalid type renaming environment"]
       Just syms -> do n <- located pn
                       mapM_ recordUse syms
                       record (MultipleSyms n syms)
                       return (Just (head syms))
       Nothing -> return Nothing

renameType :: PName -> RenameM Name
renameType pn =
  do mb <- typeExists pn
     case mb of
       Just n -> return n

       -- This is an unbound value. Record an error and invent a bogus real name
       -- for it.
       Nothing ->
         do ro <- RenameM ask
            let n = Located { srcRange = roLoc ro, thing = pn }

            case Map.lookup pn (neExprs (roNames ro)) of

              -- values exist with the same name, so throw a different error
              Just _ -> record (ExpectedType n)

              -- no terms with the same name, so the type is just unbound
              Nothing -> record (UnboundType n)

            mkFakeName pn

-- | Assuming an error has been recorded already, construct a fake name that's
-- not expected to make it out of the renamer.
mkFakeName :: PName -> RenameM Name
mkFakeName pn =
  do ro <- RenameM ask
     liftSupply (mkParameter (getIdent pn) (roLoc ro))

-- | Rename a schema, assuming that none of its type variables are already in
-- scope.
instance Rename Schema where
  rename s = snd `fmap` renameSchema s

-- | Rename a schema, assuming that the type variables have already been brought
-- into scope.
renameSchema :: Schema PName -> RenameM (NamingEnv,Schema Name)
renameSchema (Forall ps p ty loc) =
  renameQual ps p $ \ps' p' ->
    do ty' <- rename ty
       pure (Forall ps' p' ty' loc)

-- | Rename a qualified thing.
renameQual :: [TParam PName] -> [Prop PName] ->
              ([TParam Name] -> [Prop Name] -> RenameM a) ->
              RenameM (NamingEnv, a)
renameQual as ps k =
  do env <- liftSupply (namingEnv' as)
     res <- shadowNames env $ do as' <- traverse rename as
                                 ps' <- traverse rename ps
                                 k as' ps'
     pure (env,res)

instance Rename TParam where
  rename TParam { .. } =
    do n <- renameType tpName
       return TParam { tpName = n, .. }

instance Rename Prop where
  rename (CType t) = CType <$> rename t


instance Rename Type where
  rename ty0 =
    case ty0 of
      TFun a b       -> TFun <$> rename a <*> rename b
      TSeq n a       -> TSeq <$> rename n <*> rename a
      TBit           -> return TBit
      TNum c         -> return (TNum c)
      TChar c        -> return (TChar c)
      TUser qn ps    -> TUser    <$> renameType qn <*> traverse rename ps
      TTyApp fs      -> TTyApp   <$> traverse (traverse rename) fs
      TRecord fs     -> TRecord  <$> traverse (traverse rename) fs
      TTuple fs      -> TTuple   <$> traverse rename fs
      TWild          -> return TWild
      TLocated t' r  -> withLoc r (TLocated <$> rename t' <*> pure r)
      TParens t'     -> TParens <$> rename t'
      TInfix a o _ b -> do o' <- renameTypeOp o
                           a' <- rename a
                           b' <- rename b
                           mkTInfix a' o' b'

mkTInfix :: Type Name -> (Located Name, Fixity) -> Type Name -> RenameM (Type Name)

mkTInfix t@(TInfix x o1 f1 y) op@(o2,f2) z =
  case compareFixity f1 f2 of
    FCLeft  -> return (TInfix t o2 f2 z)
    FCRight -> do r <- mkTInfix y op z
                  return (TInfix x o1 f1 r)
    FCError -> do record (FixityError o1 f1 o2 f2)
                  return (TInfix t o2 f2 z)

mkTInfix (TLocated t' _) op z =
  mkTInfix t' op z

mkTInfix t (o,f) z =
  return (TInfix t o f z)


-- | Rename a binding.
instance Rename Bind where
  rename b      = do
    n'    <- rnLocated renameVar (bName b)
    mbSig <- traverse renameSchema (bSignature b)
    shadowNames (fst `fmap` mbSig) $
      do (patEnv,pats') <- renamePats (bParams b)
         -- NOTE: renamePats will generate warnings, so we don't need to trigger
         -- them again here.
         e'             <- shadowNames' CheckNone patEnv (rnLocated rename (bDef b))
         return b { bName      = n'
                  , bParams    = pats'
                  , bDef       = e'
                  , bSignature = snd `fmap` mbSig
                  , bPragmas   = bPragmas b
                  }

instance Rename BindDef where
  rename DPrim     = return DPrim
  rename (DExpr e) = DExpr <$> rename e

-- NOTE: this only renames types within the pattern.
instance Rename Pattern where
  rename p      = case p of
    PVar lv         -> PVar <$> rnLocated renameVar lv
    PWild           -> pure PWild
    PTuple ps       -> PTuple   <$> traverse rename ps
    PRecord nps     -> PRecord  <$> traverse (traverse rename) nps
    PList elems     -> PList    <$> traverse rename elems
    PTyped p' t     -> PTyped   <$> rename p'    <*> rename t
    PSplit l r      -> PSplit   <$> rename l     <*> rename r
    PLocated p' loc -> withLoc loc
                     $ PLocated <$> rename p'    <*> pure loc

-- | Note that after this point the @->@ updates have an explicit function
-- and there are no more nested updates.
instance Rename UpdField where
  rename (UpdField h ls e) =
    -- The plan:
    -- x =  e       ~~~>        x = e
    -- x -> e       ~~~>        x -> \x -> e
    -- x.y = e      ~~~>        x -> { _ | y = e }
    -- x.y -> e     ~~~>        x -> { _ | y -> e }
    case ls of
      l : more ->
       case more of
         [] -> case h of
                 UpdSet -> UpdField UpdSet [l] <$> rename e
                 UpdFun -> UpdField UpdFun [l] <$> rename (EFun emptyFunDesc [PVar p] e)
                       where
                       p = UnQual . selName <$> last ls
         _ -> UpdField UpdFun [l] <$> rename (EUpd Nothing [ UpdField h more e])
      [] -> panic "rename@UpdField" [ "Empty label list." ]


instance Rename FunDesc where
  rename (FunDesc nm offset) =
    do nm' <- traverse renameVar nm
       pure (FunDesc nm' offset)

instance Rename Statement where
  rename stmt = case stmt of
    SAssign{}   -> panic "rename Statement" ["SAssign should be removed by NoPat"]
    SMonadBind p e ->
      do let (nm,tps) = splitSimpleP p
         nm'  <- rnLocated renameVar nm
         tps' <- traverse rename tps
         let p' = foldl PTyped (PVar nm') tps'
         SMonadBind p' <$> rename e
    SBind b     -> SBind <$> rename b
    SReturn e   -> SReturn <$> rename e
    SIf e xs ys -> SIf <$> rename e <*> traverse rename xs <*> traverse rename ys
    SWhile e xs -> SWhile <$> rename e <*> traverse rename xs
    SFor ms xs  -> do (env,ms') <- renameArm ms
                      shadowNames' CheckOverlap env (SFor ms' <$> traverse rename xs)

instance Rename Expr where
  rename expr = case expr of
    EVar n          -> EVar <$> renameVar n
    ELit l          -> return (ELit l)
    ENeg e          -> ENeg    <$> rename e
    EComplement e   -> EComplement
                               <$> rename e
    EGenerate e     -> EGenerate
                               <$> rename e
    ETuple es       -> ETuple  <$> traverse rename es
    ERecord fs      -> ERecord <$> traverse (traverse rename) fs
    ESel e' s       -> ESel    <$> rename e' <*> pure s
    EUpd mb fs      -> do checkLabels fs
                          EUpd <$> traverse rename mb <*> traverse rename fs
    EList es        -> EList   <$> traverse rename es
    EFromTo s n e t -> EFromTo <$> rename s
                               <*> traverse rename n
                               <*> rename e
                               <*> traverse rename t
    EInfFrom a b    -> EInfFrom<$> rename a  <*> traverse rename b
    EComp e' bs     -> do arms' <- traverse renameArm bs
                          let (envs,bs') = unzip arms'
                          -- NOTE: renameArm will generate shadowing warnings; we only
                          -- need to check for repeated names across multiple arms
                          shadowNames' CheckOverlap envs (EComp <$> rename e' <*> pure bs')
    EApp f x        -> EApp    <$> rename f  <*> rename x
    EAppT f ti      -> EAppT   <$> rename f  <*> traverse rename ti
    EIf b t f       -> EIf     <$> rename b  <*> rename t  <*> rename f
    EWhere e' ds    -> do ns <- getNS
                          shadowNames (map (InModule ns) ds) $
                            EWhere <$> rename e' <*> traverse rename ds
    EProcedure ss   -> renameProc ss Nothing
    EMonadAction b p ss -> renameProc ss (Just (b,p))

    ETyped e' ty    -> ETyped  <$> rename e' <*> rename ty
    ETypeVal ty     -> ETypeVal<$> rename ty
    EFun desc ps e' -> do desc' <- rename desc
                          (env,ps') <- renamePats ps
                          -- NOTE: renamePats will generate warnings, so we don't
                          -- need to duplicate them here
                          shadowNames' CheckNone env (EFun desc' ps' <$> rename e')
    ELocated e' r   -> withLoc r
                     $ ELocated <$> rename e' <*> pure r

    ESplit e        -> ESplit  <$> rename e
    EParens p       -> EParens <$> rename p
    EInfix x y _ z  -> do op <- renameOp y
                          x' <- rename x
                          z' <- rename z
                          mkEInfix x' op z'

renameProc :: [Statement PName] -> Maybe (PName,PName) -> RenameM (Expr Name)
renameProc ss monad =
  do ns <- getNS
     monad' <- traverse (\ (b,p) -> (,) <$> renameVar b <*> renameVar p) monad
     ss' <- shadowNames (ProcEnv ns ss) (traverse rename ss)
     expr <- compileProc ss' monad'

     trace (unlines
        [ "Compiled Procedure"
        , show (nest 4 (pp (EProcedure ss)))
        , show (nest 4 (pp expr))
        ]) (return expr)

--     return expr


checkLabels :: [UpdField PName] -> RenameM ()
checkLabels = foldM_ check [] . map labs
  where
  labs (UpdField _ ls _) = ls

  check done l =
    do case find (overlap l) done of
         Just l' -> record (OverlappingRecordUpdate (reLoc l) (reLoc l'))
         Nothing -> pure ()
       pure (l : done)

  overlap xs ys =
    case (xs,ys) of
      ([],_)  -> True
      (_, []) -> True
      (x : xs', y : ys') -> same x y && overlap xs' ys'

  same x y =
    case (thing x, thing y) of
      (TupleSel a _, TupleSel b _)   -> a == b
      (ListSel  a _, ListSel  b _)   -> a == b
      (RecordSel a _, RecordSel b _) -> a == b
      _                              -> False

  reLoc xs = (head xs) { thing = map thing xs }


mkEInfix :: Expr Name             -- ^ May contain infix expressions
         -> (Located Name,Fixity) -- ^ The operator to use
         -> Expr Name             -- ^ Will not contain infix expressions
         -> RenameM (Expr Name)

mkEInfix e@(EInfix x o1 f1 y) op@(o2,f2) z =
   case compareFixity f1 f2 of
     FCLeft  -> return (EInfix e o2 f2 z)

     FCRight -> do r <- mkEInfix y op z
                   return (EInfix x o1 f1 r)

     FCError -> do record (FixityError o1 f1 o2 f2)
                   return (EInfix e o2 f2 z)

mkEInfix (ELocated e' _) op z =
     mkEInfix e' op z

mkEInfix e (o,f) z =
     return (EInfix e o f z)


renameOp :: Located PName -> RenameM (Located Name, Fixity)
renameOp ln =
  withLoc ln $
  do n <- renameVar (thing ln)
     fixity <- lookupFixity n
     return (ln { thing = n }, fixity)

renameTypeOp :: Located PName -> RenameM (Located Name, Fixity)
renameTypeOp ln =
  withLoc ln $
  do n <- renameType (thing ln)
     fixity <- lookupFixity n
     return (ln { thing = n }, fixity)

lookupFixity :: Name -> RenameM Fixity
lookupFixity n =
  case nameFixity n of
    Just fixity -> return fixity
    Nothing     -> return defaultFixity -- FIXME: should we raise an error instead?

instance Rename TypeInst where
  rename ti = case ti of
    NamedInst nty -> NamedInst <$> traverse rename nty
    PosInst ty    -> PosInst   <$> rename ty

renameArm :: [Match PName] -> RenameM (NamingEnv,[Match Name])

renameArm (m:ms) =
  do (me,m') <- renameMatch m
     -- NOTE: renameMatch will generate warnings, so we don't
     -- need to duplicate them here
     shadowNames' CheckNone me $
       do (env,rest) <- renameArm ms

          -- NOTE: the inner environment shadows the outer one, for examples
          -- like this:
          --
          -- [ x | x <- xs, let x = 10 ]
          return (env `shadowing` me, m':rest)

renameArm [] =
     return (mempty,[])

-- | The name environment generated by a single match.
renameMatch :: Match PName -> RenameM (NamingEnv,Match Name)

renameMatch (Match p e) =
  do (pe,p') <- renamePat p
     e'      <- rename e
     return (pe,Match p' e')

renameMatch (MatchLet b) =
  do ns <- getNS
     be <- liftSupply (namingEnv' (InModule ns b))
     b' <- shadowNames be (rename b)
     return (be,MatchLet b')

-- | Rename patterns, and collect the new environment that they introduce.
renamePat :: Pattern PName -> RenameM (NamingEnv, Pattern Name)
renamePat p =
  do pe <- patternEnv p
     p' <- shadowNames pe (rename p)
     return (pe, p')



-- | Rename patterns, and collect the new environment that they introduce.
renamePats :: [Pattern PName] -> RenameM (NamingEnv,[Pattern Name])
renamePats  = loop
  where
  loop ps = case ps of

    p:rest -> do
      pe <- patternEnv p
      shadowNames pe $
        do p'           <- rename p
           (env',rest') <- loop rest
           return (pe `mappend` env', p':rest')

    [] -> return (mempty, [])

patternEnv :: Pattern PName -> RenameM NamingEnv
patternEnv  = go
  where
  go (PVar Located { .. }) =
    do n <- liftSupply (mkParameter (getIdent thing) srcRange)
       return (singletonE thing n)

  go PWild            = return mempty
  go (PTuple ps)      = bindVars ps
  go (PRecord fs)     = bindVars (fmap snd (recordElements fs))
  go (PList ps)       = foldMap go ps
  go (PTyped p ty)    = go p `mappend` typeEnv ty
  go (PSplit a b)     = go a `mappend` go b
  go (PLocated p loc) = withLoc loc (go p)

  bindVars []     = return mempty
  bindVars (p:ps) =
    do env <- go p
       shadowNames env $
         do rest <- bindVars ps
            return (env `mappend` rest)


  typeEnv (TFun a b) = bindTypes [a,b]
  typeEnv (TSeq a b) = bindTypes [a,b]

  typeEnv TBit       = return mempty
  typeEnv TNum{}     = return mempty
  typeEnv TChar{}    = return mempty

  typeEnv (TUser pn ps) =
    do mb <- typeExists pn
       case mb of

         -- The type is already bound, don't introduce anything.
         Just _ -> bindTypes ps

         Nothing

           -- The type isn't bound, and has no parameters, so it names a portion
           -- of the type of the pattern.
           | null ps ->
             do loc <- curLoc
                n   <- liftSupply (mkParameter (getIdent pn) loc)
                return (singletonT pn n)

           -- This references a type synonym that's not in scope. Record an
           -- error and continue with a made up name.
           | otherwise ->
             do loc <- curLoc
                record (UnboundType (Located loc pn))
                n   <- liftSupply (mkParameter (getIdent pn) loc)
                return (singletonT pn n)

  typeEnv (TRecord fs)      = bindTypes (map snd (recordElements fs))
  typeEnv (TTyApp fs)       = bindTypes (map value fs)
  typeEnv (TTuple ts)       = bindTypes ts
  typeEnv TWild             = return mempty
  typeEnv (TLocated ty loc) = withLoc loc (typeEnv ty)
  typeEnv (TParens ty)      = typeEnv ty
  typeEnv (TInfix a _ _ b)  = bindTypes [a,b]

  bindTypes [] = return mempty
  bindTypes (t:ts) =
    do env' <- typeEnv t
       shadowNames env' $
         do res <- bindTypes ts
            return (env' `mappend` res)


instance Rename Match where
  rename m = case m of
    Match p e  ->                  Match    <$> rename p <*> rename e
    MatchLet b -> shadowNamesNS b (MatchLet <$> rename b)

instance Rename TySyn where
  rename (TySyn n f ps ty) =
    shadowNames ps $ TySyn <$> rnLocated renameType n
                           <*> pure f
                           <*> traverse rename ps
                           <*> rename ty

instance Rename PropSyn where
  rename (PropSyn n f ps cs) =
    shadowNames ps $ PropSyn <$> rnLocated renameType n
                             <*> pure f
                             <*> traverse rename ps
                             <*> traverse rename cs


data BBTerm
  = BBReturn (Expr Name)
  | BBJump Integer
  | BBBranch (Expr Name) Integer Integer
  | BBMonadBind Name [Type Name] (Expr Name) Integer

data BasicBlock =
  BasicBlock
  { _bbLabel :: Integer
  , bbStmts :: [Bind Name]
  , bbTerm  :: BBTerm
  }

data CFG =
  CFG
  { cfgBlocks  :: Map Integer BasicBlock
  , cfgAllDefs :: Set Name
  }

emptyCFG :: CFG
emptyCFG = CFG mempty mempty

buildCFG :: [Integer] -> CFG -> Integer -> Maybe BBTerm -> [Statement Name] -> RenameM ([Integer], CFG)
buildCFG labels cfg lbl mterm = processBB [] mempty
  where
    finishBB bnds defs term =
      CFG
      { cfgBlocks  = Map.insert lbl (BasicBlock lbl (reverse bnds) term) (cfgBlocks cfg)
      , cfgAllDefs = Set.union defs (cfgAllDefs cfg)
      }

    processBB bnds defs [] =
      case mterm of
        Nothing   -> error "Unterminated procedure" -- TODO, real error handling
        Just term -> pure (labels, finishBB bnds defs term)

    processBB bnds defs (s:ss) =
      case s of
        SAssign{} -> panic "buildCFG" ["Unexpected pattern assignement in renamer"]
        SMonadBind p e ->
          do let (lz:labels') = labels
             let (nm,ts) = splitSimpleP p
             let cfg' = finishBB bnds (Set.insert (thing nm) defs) (BBMonadBind (thing nm) ts e lz)
             buildCFG labels' cfg' lz mterm ss
        SBind b   -> processBB (b:bnds) (Set.insert (thing (bName b)) defs) ss
        SReturn e -> pure (labels, finishBB bnds defs (BBReturn e))
        SWhile e xs ->
          do let (lx:lz:labels') = labels
             let cfg' = finishBB bnds defs (BBBranch e lx lz)
             (labelsx, cfgx) <- buildCFG labels' cfg' lx (Just (BBBranch e lx lz)) xs
             buildCFG labelsx cfgx lz mterm ss
        SIf e xs [] ->
          do let (lx:lz:labels') = labels
             let cfg' = finishBB bnds defs (BBBranch e lx lz)
             (labelsx, cfgx) <- buildCFG labels' cfg' lx (Just (BBJump lz)) xs
             buildCFG labelsx cfgx lz mterm ss
        SIf e xs ys ->
          do let (lx:ly:lz:labels') = labels
             let cfg' = finishBB bnds defs (BBBranch e lx ly)
             (labelsx, cfgx) <- buildCFG labels' cfg' lx (Just (BBJump lz)) xs
             (labelsy, cfgy) <- buildCFG labelsx cfgx ly (Just (BBJump lz)) ys
             buildCFG labelsy cfgy lz mterm ss
        SFor ms xs ->
          do s' <- processFor ms xs
             processBB bnds defs (s' ++ ss)

    simpleBind nm e =
      Bind
      { bName   = Located (nameLoc nm) nm
      , bParams = []
      , bDef    = at e (Located emptyRange (DExpr e))
      , bSignature = Nothing
      , bInfix = False
      , bFixity = Nothing
      , bPragmas = []
      , bMono = True
      , bDoc = Nothing
      }

--    prel ident = EVar <$> renameVar (mkQual preludeName ident)
    prel ident = EVar <$> renameVar (mkUnqual ident)

    -- reduce for loops down to while loops
    processFor [] body = pure body
    processFor (MatchLet b:ms) body = (SBind b:) <$> processFor ms body
    processFor (Match p e:ms) body =
      do idxVar <- liftSupply (mkParameter (packIdent "idx") emptyRange) -- TODO location info
         seqVar <- liftSupply (mkParameter (packIdent "seq") emptyRange) -- TODO location info
         addExpr    <- prel "+"
         lookupExpr <- prel "@"
         ltExpr     <- prel "<"
         lengthExpr <- prel "length"
         let idxInit = simpleBind idxVar (ELit (ECNum 0 (DecLit "0")))
         let idxUpd  = simpleBind idxVar (addExpr `EApp` EVar idxVar `EApp` (ELit (ECNum 1 (DecLit "1"))))
         let seqInit = simpleBind seqVar e
         let testE = ltExpr `EApp` EVar idxVar `EApp` (lengthExpr `EApp` EVar seqVar)
         let (pnm, ptys) = splitSimpleP p
         let pbnd = simpleBind (thing pnm) (foldl ETyped (lookupExpr `EApp` EVar seqVar `EApp` EVar idxVar) ptys)

         pure [ SBind seqInit, SBind idxInit, SWhile testE [SBind pbnd, SFor ms body, SBind idxUpd] ]


bbDefUses :: Set Name -> BasicBlock -> (Set Name, Set Name)
bbDefUses procNames bb = goBinds (bbStmts bb) mempty mempty
  where
    exprNms defs e = Set.intersection procNames (Set.difference (namesE e) defs)

    goTerm defs uses =
      case bbTerm bb of
        BBReturn e     -> (defs, Set.union uses (exprNms defs e))
        BBJump _       -> (defs, uses)
        BBBranch e _ _ -> (defs, Set.union uses (exprNms defs e))
        BBMonadBind nm _ts e _ -> (Set.insert nm defs, Set.union uses (exprNms defs e))

    goBinds [] defs uses = goTerm defs uses
    goBinds (b:bs) defs uses =
      let (xs,ys) = namesB b
       in goBinds bs ( Set.union defs (Set.fromList (map thing xs)) )
                     ( Set.union uses (Set.intersection procNames (Set.difference ys defs)) )

successors :: BasicBlock -> [Integer]
successors bb =
  case bbTerm bb of
    BBReturn{}          -> []
    BBJump l            -> [l]
    BBBranch _ l1 l2    -> [l1,l2]
    BBMonadBind _ _ _ l -> [l]

cfgUses :: CFG -> Map Integer (BasicBlock, Set Name)
cfgUses cfg = fmap (\(blk,_,u,_) -> (blk,u)) (work (map fst allBlocks) False initialMap)
  where
    allBlocks = Map.toDescList (cfgBlocks cfg)
    initialMap = Map.fromList [ (b, (blk,ds,us,successors blk))
                              | (b, blk) <- allBlocks
                              , let (ds,us) = bbDefUses (cfgAllDefs cfg) blk
                              ]

    work [] False m = m
    work [] True  m = work (map fst allBlocks) False m
    work (b:bs) revisit m =
      case Map.lookup b m of
        Nothing -> panic "cfgDefUses" ["Missing block number", show b]
        Just (blk, bDefs, bUses, succs) ->
          let succUses = Set.unions [ u | s <- succs, (_,_,u,_) <- maybeToList (Map.lookup s m) ]
              bUses'   = Set.union bUses (Set.difference succUses bDefs)
              m'       = Map.insert b (blk, bDefs, bUses', succs) m
           in if bUses == bUses' then work bs revisit m else work bs True m'

computeLabelMap :: CFG -> RenameM (Map Integer (Name, BasicBlock, [Name]))
computeLabelMap cfg = Map.traverseWithKey allocLabel useMap
  where
    useMap = cfgUses cfg
    allocLabel l (blk,uses) =
      do lnm <- liftSupply (mkParameter (packIdent ("label"++show l)) emptyRange) -- TODO, range info
         pure (lnm, blk, Set.toList uses)

compileBB :: Map Integer (Name, BasicBlock, [Name]) -> Maybe (Name, Name) -> (Name, BasicBlock, [Name]) -> RenameM (Bind Name)
compileBB labelMap monad (blockLabelName, blk, inputVars) =
    do (ssaMap, formals) <- startBlock inputVars [] mempty
       (ssaMap', lets)   <- processBinds ssaMap (bbStmts blk) []
       termExpr          <- finishBlock ssaMap' (bbTerm blk)
       let blockBody =
            if null lets then termExpr else EWhere termExpr (map DBind lets)
       pure Bind
            { bName   = Located emptyRange blockLabelName -- TODO, range info
            , bParams = [ PVar (Located (nameLoc f) f) | f <- formals ]
            , bDef    = Located emptyRange (DExpr blockBody) -- TODO, range info
            , bSignature = Nothing
            , bInfix  = False
            , bFixity = Nothing
            , bPragmas = []
            , bMono = True
            , bDoc = Nothing
            }

  where
    startBlock []     as ssaMap = pure (ssaMap, reverse as)
    startBlock (i:is) as ssaMap =
      do a <- liftSupply (mkUniqueParameter (nameIdent i) (nameLoc i)) -- Freshen the name
         startBlock is (a:as) (Map.insert i a ssaMap)

    processBinds ssaMap [] lets = pure (ssaMap, reverse lets)
    processBinds ssaMap (b:bs) lets =
      do let bnm = thing (bName b)
         bnm' <- liftSupply (mkUniqueParameter (nameIdent bnm) (nameLoc bnm)) -- Freshen the name
         let def' = fmap (updateVars ssaMap) (bDef b)
         let b' = b{ bName = (bName b){ thing = bnm' }
                   , bDef = def'
                   }
         let ssaMap' = Map.insert bnm bnm' ssaMap
         processBinds ssaMap' bs (b':lets)

    finishBlock ssaMap term =
      case term of
        BBReturn e ->
          case monad of
            Just (_,p) -> return (EApp (EVar p) (updateVars ssaMap e))
            Nothing    -> return (updateVars ssaMap e)

        BBMonadBind nm ts e l ->
          case monad of
            Just (bnd,_) ->
              do let e' = updateVars ssaMap e
                 let loc = nameLoc nm
                 nm' <- liftSupply (mkUniqueParameter (nameIdent nm) loc)
                 let p = foldl PTyped (PVar (Located loc nm')) ts
                 l' <- jumpTarget (Map.insert nm nm' ssaMap) l
                 pure (EVar bnd `EApp` e' `EApp` EFun emptyFunDesc [p] l')
            Nothing -> error "No monadic binds in a pure procedure"

        BBJump l -> jumpTarget ssaMap l

        BBBranch e l1 l2 ->
          do let e' = updateVars ssaMap e
             l1' <- jumpTarget ssaMap l1
             l2' <- jumpTarget ssaMap l2
             pure (EIf e' l1' l2')

    updateVars :: Functor f => Map.Map Name Name -> f Name -> f Name
    updateVars ssaMap = fmap (\v -> fromMaybe v (Map.lookup v ssaMap))

    jumpTarget ssaMap l =
      case Map.lookup l labelMap of
        Nothing -> panic "jumpTarget" ["Unknown block number", show l]
        Just (tgtNm,_,vars) ->
          do let vars' = updateVars ssaMap vars
             pure (foldl EApp (EVar tgtNm) (map EVar vars'))

compileProc :: [Statement Name] -> Maybe (Name,Name) -> RenameM (Expr Name)
compileProc ss monad =
  do (_,cfg) <- buildCFG [1..] emptyCFG 0 Nothing ss
     lblMap <- computeLabelMap cfg
     blockBnds <- mapM (compileBB lblMap monad . snd) (Map.toList lblMap)
     case Map.lookup 0 lblMap of
       Just (entryLab, _, inputs) ->
         do inputs' <- mapM (renameVar . mkUnqual . nameIdent) inputs
            pure (EWhere (foldl EApp (EVar entryLab) (map EVar inputs')) (map DBind blockBnds))
       Nothing -> panic "compileProc" ["Missing entry point for procedure!"]
