{-# LANGUAGE BlockArguments #-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE ExistentialQuantification #-}
{-# LANGUAGE KindSignatures #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE ScopedTypeVariables #-}

module Cryptol.TypeCheck.Solver.Numeric.Sampling.Preconstraints where

import Control.Monad
import Control.Monad.State (StateT (runStateT), gets, modify, evalStateT)
import Control.Monad.Writer (MonadWriter (tell), WriterT(runWriterT))
import Cryptol.TypeCheck.Solver.Numeric.Sampling.Base
import Cryptol.TypeCheck.Solver.Numeric.Sampling.Exp (Exp(..), Var(..))
import qualified Cryptol.TypeCheck.Solver.Numeric.Sampling.Exp as Exp
import Cryptol.TypeCheck.Solver.Numeric.Sampling.Q
import Cryptol.TypeCheck.TCon
import Cryptol.TypeCheck.Type
import Data.Vector (Vector)
import qualified Data.Vector as V
import Data.List (elemIndex)
import Cryptol.TypeCheck.PP (PP (ppPrec), pp, text, pretty)
import Control.Monad.Except (MonadError(throwError))

-- | Preconstraints
data Preconstraints = Preconstraints
  { preprops :: [PProp],
    -- params :: Vector SamplingParam,
    toVar :: TParam -> Var,
    nVars :: Int
  }

instance Show Preconstraints where
  show precons = unwords  
    [ "Preconstraints {"
    , "preprops = " ++ show (preprops precons) 
    , "toVar = <function :: TParam -> Var>"
    , "nVars = " ++ show (nVars precons)
    , "}"
    ]

-- data SamplingParam = SPTParam TParam | SPFresh Int

-- instance Show SamplingParam where 
--   show = \case 
--     SPTParam tp -> "SPTParam " ++ pretty tp
--     SPFresh n -> "SPFresh " ++ show n

-- instance PP SamplingParam where 
--   ppPrec i = \case
--     SPTParam tparam -> pp tparam
--     SPFresh n -> text $ "fresh(" ++ show n ++ ")"

emptyPreconstraints :: Vector TParam -> Preconstraints
emptyPreconstraints tparams =
  Preconstraints
    { preprops = []
      -- params = SPTParam <$> tparams
    , toVar = \tparam -> error $ "could not find type parameter `" ++ pretty tparam ++ "`"
    , nVars = 0
    }

countVars :: Preconstraints -> Int
-- countVars precons = V.length (params precons)
countVars = nVars


addPProps :: [PProp] -> Preconstraints -> Preconstraints
addPProps preprops_ precons = precons {preprops = preprops_ <> preprops precons}

-- | Subset of PProps that are handled by literal sampler.
data PProp
  = PPEqual PExp PExp
  | PPNeq PExp PExp
  | PPGeq PExp PExp
  | PPFin PExp
  deriving (Show)

data PExp
  = PEConst Q
  | PETerm Q Var
  | PEOp2 POp2 PExp PExp
  deriving (Show)

data POp2 = PAdd | PSub | PMul | PDiv | PMod | PPow
  deriving (Show)

-- | fromProps
-- Expects that all available substitions have been applied to the props.
-- Preserves order of `[TParam]`.
fromProps ::
  [TParam] ->
  [Prop] ->
  SamplingM Preconstraints
fromProps tparams props = do
  pprops <- foldM fold (emptyPreconstraints $ V.fromList tparams) props
  debug' 0 $ "pprops = " ++ show pprops
  pprops <- normalizePreconstraints pprops
  debug' 0 $ "pprops <- normalizePreconstraints pprops"
  debug' 0 $ "pprops = " ++ show pprops
  pure pprops
  where
    fold :: Preconstraints -> Prop -> SamplingM Preconstraints
    fold precons prop = do
      debug' 0 $ "fromProps.fold: prop = " ++ pretty prop
      case prop of
        -- type predicates
        TCon (PC pc) ts -> case pc of
          PEqual -> proc2 PPEqual ts
          PNeq -> proc2 PPNeq ts
          PGeq -> proc2 PPGeq ts
          PFin -> proc1 PPFin ts
          PTrue -> pure precons -- trivial
          _ -> undefined -- bad
        prop -> throwError $ SamplingError "fromProps" $
          "cannot handle prop of the form: `" ++ show prop ++ "`"
      where
        proc2 con ts =
          toPExp `traverse` ts >>= \case
            [e1, e2] -> do
              let pprop = con e1 e2
              debug' 0 $ "fromProps.fold.proc2 (" ++ pretty prop ++ ") = (" ++ show pprop ++ ")"
              pure $ addPProps [pprop] precons
            _ -> undefined -- bad number of args
        proc1 con ts =
          toPExp `traverse` ts >>= \case
            [e] -> pure $ addPProps [con e] precons
            _ -> undefined -- bad number of args

    toPExp :: Type -> SamplingM PExp
    toPExp typ = do
      pe <- case typ of
        TCon tcon ts -> case tcon of
          -- type constants
          TC tc -> case tc of
            TCNum n -> pure . PEConst $ toQ n
            -- TCInf -> pure . PEConst $ Inf -- TODO: how to handle constant inf?
            TCAbstract _ut -> undefined -- TODO: support user-defined type constraints
            _ -> undefined -- unsupported type function
            -- type functions
          TF tf -> case tf of
            TCAdd -> proc2 (PEOp2 PAdd) ts
            TCSub -> proc2 (PEOp2 PSub) ts
            TCMul -> proc2 (PEOp2 PMul) ts
            TCDiv -> proc2 (PEOp2 PDiv) ts
            TCMod -> proc2 (PEOp2 PMod) ts
            TCExp -> proc2 (PEOp2 PPow) ts
            _ -> undefined -- unsupported type function
            where
              proc2 con = \case
                [t1, t2] -> con <$> toPExp t1 <*> toPExp t2
                _ -> undefined -- bad num of args
          _ -> undefined -- unsupported type
        TVar tv -> pure $ PETerm 1 (iTVar tv)
        TUser _na _tys _ty -> undefined -- TODO: support user-defined types
        TNewtype _new _tys -> undefined -- TODO: support user-defined newtypes
        _ -> undefined -- unsupported type function
      debug' 0 $ "fromProps.toPExp (" ++ pretty typ ++ ") = (" ++ show pe ++ ")"
      pure pe
      where
        iTVar :: TVar -> Var
        iTVar = \case
          TVFree {} -> undefined -- shouldn't be dealing with free vars here
          TVBound tparam ->
            maybe undefined Var (elemIndex tparam tparams)

{-
- Check that all `a mod n` have `n` a constant
- Check that all `m^n` have `m` and `n` constant
- Check that all `n*a` has at most one of `n`, `a` a variable
- Replace `a mod n` with `b` and add equality `b = c*n + a`, where
  `n` is a constant.
- Replace `a - b` with `a + (-b)`
- Apply distributivity
- Apply commutativity of addition to combine constant terms at the end a sum
- Apply commutativity of addition to combine terms in a sum of products
- Evaluate operations over constants
-}
normalizePreconstraints :: Preconstraints -> SamplingM Preconstraints
normalizePreconstraints precons = do
  -- TODO: the state's final value is the number of fresh variables introduced
  -- via `mod` and perhaps other kinds of expansions
  ((preprops', preprops''), i) <-
    flip runStateT (countVars precons) . runWriterT $
      normPProp `traverse` preprops precons
  pure precons 
    { preprops = preprops' <> preprops'' 
    -- , params = params precons <> V.generate i SPFresh
    , nVars = nVars precons + i
    }
  where

  normPProp :: PProp -> WriterT [PProp] (StateT Int SamplingM) PProp
  normPProp = \case
    PPEqual pe1 pe2 -> PPEqual <$> normPExp pe1 <*> normPExp pe2
    PPNeq _a _b -> do
      undefined -- not sure how to handle Neq
    PPGeq a b -> do
      -- a >= b ~~> a = b + c, where c is fresh
      c <- freshVar
      normPProp $ PPEqual a (PEOp2 PAdd b (PETerm 1 c))
    PPFin pe -> pure $ PPFin pe -- don't need to normalize this

  normPExp :: PExp -> WriterT [PProp] (StateT Int SamplingM) PExp
  normPExp pe =
    step pe >>= \case
      Just pe' -> normPExp pe'
      Nothing -> pure pe
    where
      -- writes the new equations generated from expanding mod
      step :: PExp -> WriterT [PProp] (StateT Int SamplingM) (Maybe PExp)
      step = \case
        -- PEConst
        PEConst _ -> pure Nothing
        -- PETerm
        PETerm 0 _ -> pure . Just $ PEConst 0
        PETerm _ _ -> pure Nothing
        -- PEOp2
        PEOp2 po pe1 pe2 -> do
          pe1' <- normPExp pe1
          pe2' <- normPExp pe2
          case po of
            -- combine constants
            PAdd | PEConst n1 <- pe1', PEConst n2 <- pe2' -> pure . Just . PEConst $ n1 + n2
            PMul | PEConst n1 <- pe1', PEConst n2 <- pe2' -> pure . Just . PEConst $ n1 * n2
            PDiv | PEConst n1 <- pe1', PEConst n2 <- pe2' -> pure . Just . PEConst $ n1 / n2
            -- `m mod n` where both `m`, `n` are constant
            PMod
              | PEConst n1 <- pe1',
                PEConst n2 <- pe2',
                Just z1 <- (fromQ n1 :: Maybe Int),
                Just z2 <- (fromQ n2 :: Maybe Int) ->
                pure . Just . PEConst . toQ $ z1 `mod` z2
            -- `m ^^ n` requires that `m`, `n` are constant
            PPow
              | PEConst n1 <- pe1',
                PEConst n2 <- pe2',
                Just z2 <- (fromQ n2 :: Maybe Int) ->
                pure . Just . PEConst $ n1 ^^ z2
            -- `a mod n` where only `n` is constant
            PMod | PEConst n <- pe2' -> do
              -- `a mod n` is replaced by `b` such that `b = a - n*c`
              -- where `b` and `c` are fresh
              let a = pe2'
              b <- freshVar
              c <- freshVar
              tell [PPEqual (PETerm 1 b) (PEOp2 PAdd a (PETerm n c))]
              pure . Just $ PETerm 1 b
            -- a - b ~~> a + (-b)
            PSub -> pure . Just $ PEOp2 PAdd pe1' (PEOp2 PMul (PEConst (-1)) pe2')
            -- 
            -- TODO: specify exception cases
            --
            -- only expressions that are already normalized should get here
            _ -> pure Nothing

  freshVar :: WriterT [PProp] (StateT Int SamplingM) Var
  freshVar = do
    var <- gets Var
    modify (+1)
    pure var

