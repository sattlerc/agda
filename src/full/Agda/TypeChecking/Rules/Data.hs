{-# LANGUAGE CPP #-}
{-# LANGUAGE MultiWayIf #-}

module Agda.TypeChecking.Rules.Data where

import Control.Applicative
import Control.Monad

import Data.List (genericTake)
import Data.Maybe (fromMaybe)
import qualified Data.Set as Set

import qualified Agda.Syntax.Abstract as A
import Agda.Syntax.Internal
import Agda.Syntax.Common
import Agda.Syntax.Position
import qualified Agda.Syntax.Info as Info

import Agda.TypeChecking.Monad
import Agda.TypeChecking.Monad.Builtin (primLevel)
import Agda.TypeChecking.Conversion
import Agda.TypeChecking.Substitute
import Agda.TypeChecking.MetaVars
import Agda.TypeChecking.Reduce
import Agda.TypeChecking.Pretty
import Agda.TypeChecking.Free
import Agda.TypeChecking.Forcing
import Agda.TypeChecking.Irrelevance
import Agda.TypeChecking.Telescope

import {-# SOURCE #-} Agda.TypeChecking.Rules.Term ( isType_ )

import Agda.Interaction.Options

import Agda.Utils.Except
import Agda.Utils.List
import Agda.Utils.Monad
import Agda.Utils.Permutation
import qualified Agda.Utils.Pretty as P
import Agda.Utils.Size
import Agda.Utils.Tuple
import qualified Agda.Utils.VarSet as VarSet

#include "undefined.h"
import Agda.Utils.Impossible

---------------------------------------------------------------------------
-- * Datatypes
---------------------------------------------------------------------------

-- | Type check a datatype definition. Assumes that the type has already been
--   checked.
checkDataDef :: Info.DefInfo -> QName -> [A.LamBinding] -> [A.Constructor] -> TCM ()
checkDataDef i name ps cs =
    traceCall (CheckDataDef (getRange name) (qnameName name) ps cs) $ do -- TODO!! (qnameName)

        -- Add the datatype module
        addSection (qnameToMName name)

        -- Look up the type of the datatype.
        t <- instantiateFull =<< typeOfConst name

        -- Make sure the shape of the type is visible
        let unTelV (TelV tel a) = telePi tel a
        t <- unTelV <$> telView t

        -- Top level free vars
        freeVars <- getContextSize

        -- The parameters are in scope when checking the constructors.
        dataDef <- bindParameters ps t $ \tel t0 -> do

            -- Parameters are always hidden in constructors
            let tel' = hideAndRelParams <$> tel
            -- let tel' = hideTel tel

            -- The type we get from bindParameters is Θ -> s where Θ is the type of
            -- the indices. We count the number of indices and return s.
            -- We check that s is a sort.
            let TelV ixTel s0 = telView' t0
                nofIxs = size ixTel

            s <- workOnTypes $ do
              -- Andreas, 2016-11-02 issue #2290
              -- Trying to unify the sort with a fresh sort meta which is
              -- defined outside the index telescope is the most robust way
              -- to check independence of the indices.
              -- However, it might give the dreaded "Cannot instantiate meta..."
              -- error which we replace by a more understandable error
              -- in case of a suspected dependency.
              s <- newSortMetaBelowInf
              catchError_ (addContext ixTel $ equalType s0 $ raise nofIxs $ sort s) $ \ err ->
                  if any (`freeIn` s0) [0..nofIxs - 1] then typeError . GenericDocError =<<
                     fsep [ text "The sort of" <+> prettyTCM name
                          , text "cannot depend on its indices in the type"
                          , prettyTCM t0
                          ]
                  else throwError err
              return s

            -- the small parameters are taken into consideration for --without-K
            smallPars <- smallParams tel s

            reportSDoc "tc.data.sort" 20 $ vcat
              [ text "checking datatype" <+> prettyTCM name
              , nest 2 $ vcat
                [ text "type (parameters instantiated):   " <+> prettyTCM t0
                , text "type (full):   " <+> prettyTCM t
                , text "sort:   " <+> prettyTCM s
                , text "indices:" <+> text (show nofIxs)
                , text "params:"  <+> text (show ps)
                , text "small params:" <+> text (show smallPars)
                ]
              ]
            let npars = size tel

            -- Change the datatype from an axiom to a datatype with no constructors.
            let dataDef = Datatype
                  { dataPars       = npars
                  , dataSmallPars  = Perm npars smallPars
                  , dataNonLinPars = Drop 0 $ Perm npars []
                  , dataIxs        = nofIxs
                  , dataInduction  = Inductive
                  , dataClause     = Nothing
                  , dataCons       = []     -- Constructors are added later
                  , dataSort       = s
                  , dataAbstr      = Info.defAbstract i
                  , dataMutual     = Nothing
                  }

            escapeContext npars $ do
              addConstant name $
                defaultDefn defaultArgInfo name t dataDef
                -- polarity and argOcc.s determined by the positivity checker

            -- Check the types of the constructors
            -- collect the non-linear parameters of each constructor
            nonLins <- mapM (checkConstructor name tel' nofIxs s) cs
            -- compute the ascending list of non-linear parameters of the data type
            let nonLinPars0 = Set.toAscList $ Set.unions $ map Set.fromList nonLins
                -- The constructors are analyzed in the absolute context,
                -- but the data definition happens in the relative module context,
                -- so we apply to the free module variables.
                -- Unfortunately, we lose precision here, since 'abstract', which
                -- is then performed by addConstant, cannot restore the linearity info.
                nonLinPars  = Drop freeVars $ Perm (npars + freeVars) nonLinPars0

            -- Return the data definition
            return dataDef{ dataNonLinPars = nonLinPars }

        let s      = dataSort dataDef
            cons   = map A.axiomName cs  -- get constructor names

        -- If proof irrelevance is enabled we have to check that datatypes in
        -- Prop contain at most one element.
        do  proofIrr <- proofIrrelevance
            case (proofIrr, s, cs) of
                (True, Prop, _:_:_) -> setCurrentRange cons $
                                         typeError PropMustBeSingleton
                _                   -> return ()

        -- Add the datatype to the signature with its constructors.
        -- It was previously added without them.
        addConstant name $
          defaultDefn defaultArgInfo name t $
            dataDef{ dataCons = cons }


-- | Ensure that the type is a sort.
--   If it is not directly a sort, compare it to a 'newSortMetaBelowInf'.
forceSort :: Type -> TCM Sort
forceSort t = case ignoreSharing $ unEl t of
  Sort s -> return s
  _      -> do
    s <- newSortMetaBelowInf
    equalType t (sort s)
    return s


-- | A parameter is small if its sort fits into the data sort.
--   @smallParams@ overapproximates the small parameters (in doubt: small).
smallParams :: Telescope -> Sort -> TCM [Int]
smallParams tel s = do
  -- get the types of the parameters
  let as = map (snd . unDom) $ telToList tel
  -- get the big parameters
  concat <$> do
    forM (zip [0..] as) $ \ (i, a) -> do
      -- A type is small if it is not Level or its sort is <= the data sort.
      -- In doubt (unsolvable constraints), a type is small.
      -- So, only if we have a solid error, the type is big.
      localTCState $ do
        ([] <$ do equalTerm topSort (unEl a) =<< primLevel)  -- NB: if primLevel fails, the next alternative is picked
        <|> ([i] <$ (getSort a `leqSort` s))
        <|> return []
  where
    (<|>) m1 m2 = m1 `catchError_` (const m2)

-- | Type check a constructor declaration. Checks that the constructor targets
--   the datatype and that it fits inside the declared sort.
--   Returns the non-linear parameters.
checkConstructor
  :: QName         -- ^ Name of data type.
  -> Telescope     -- ^ Parameter telescope.
  -> Nat           -- ^ Number of indices of the data type.
  -> Sort          -- ^ Sort of the data type.
  -> A.Constructor -- ^ Constructor declaration (type signature).
  -> TCM [Int]     -- ^ Non-linear parameters.
checkConstructor d tel nofIxs s (A.ScopedDecl scope [con]) = do
  setScope scope
  checkConstructor d tel nofIxs s con
checkConstructor d tel nofIxs s con@(A.Axiom _ i ai Nothing c e) =
    traceCall (CheckConstructor d tel s con) $ do
{- WRONG
      -- Andreas, 2011-04-26: the following happens to the right of ':'
      -- we may use irrelevant arguments in a non-strict way in types
      t' <- workOnTypes $ do
-}
        debugEnter c e
        -- check that we are relevant
        case getRelevance ai of
          Relevant   -> return ()
          Irrelevant -> typeError $ GenericError $ "Irrelevant constructors are not supported"
          _ -> __IMPOSSIBLE__
        -- check that the type of the constructor is well-formed
        t <- isType_ e
        -- check that the type of the constructor ends in the data type
        n <- getContextSize
        debugEndsIn t d n
        nonLinPars <- constructs n t d
        debugNonLinPars nonLinPars
        -- check which constructor arguments are determined by the type ('forcing')
        t' <- addForcingAnnotations t
        -- check that the sort (universe level) of the constructor type
        -- is contained in the sort of the data type
        -- (to avoid impredicative existential types)
        debugFitsIn s
        arity <- t' `fitsIn` s
        debugAdd c t'

        -- add parameters to constructor type and put into signature
        let con = ConHead c Inductive [] -- data constructors have no projectable fields and are always inductive
        escapeContext (size tel) $
          addConstant c $
            defaultDefn defaultArgInfo c (telePi tel t') $ Constructor
              { conPars   = size tel
              , conArity  = arity
              , conSrcCon = con
              , conData   = d
              , conAbstr  = Info.defAbstract i
              , conInd    = Inductive
              , conErased = []  -- computed during compilation to treeless
              }

        -- Add the constructor to the instance table, if needed
        when (Info.defInstance i == InstanceDef) $ do
          addNamedInstance c d

        return nonLinPars
  where
    debugEnter c e =
      reportSDoc "tc.data.con" 5 $ vcat
        [ text "checking constructor" <+> prettyTCM c <+> text ":" <+> prettyTCM e
        ]
    debugEndsIn t d n =
      reportSDoc "tc.data.con" 15 $ vcat
        [ sep [ text "checking that"
              , nest 2 $ prettyTCM t
              , text "ends in" <+> prettyTCM d
              ]
        , nest 2 $ text "nofPars =" <+> text (show n)
        ]
    debugNonLinPars ks =
      reportSDoc "tc.data.con" 15 $
        text "these constructor parameters are non-linear:" <+> text (show ks)
    debugFitsIn s =
      reportSDoc "tc.data.con" 15 $ sep
        [ text "checking that the type fits in"
        , nest 2 $ prettyTCM s
        ]
    debugAdd c t =
      reportSDoc "tc.data.con" 5 $ vcat
        [ text "adding constructor" <+> prettyTCM c <+> text ":" <+> prettyTCM t
        ]
checkConstructor _ _ _ _ _ = __IMPOSSIBLE__ -- constructors are axioms


-- | Bind the parameters of a datatype.
--
--   We allow omission of hidden parameters at the definition site.
--   Example:
--   @
--     data D {a} (A : Set a) : Set a
--     data D A where
--       c : A -> D A
--   @

bindParameters :: [A.LamBinding] -> Type -> (Telescope -> Type -> TCM a) -> TCM a
bindParameters = bindParameters' []

-- | Auxiliary function for 'bindParameters'.
bindParameters'
  :: [Type]         -- ^ @n@ replicas of type if @LamBinding@s are @DomainFree@s
                    --   that came from a @DomainFull@ of @n@ binders.
                    --   Should be comsumed whenever a @DomainFree@s are consumed.
  -> [A.LamBinding] -- ^ Bindings from definition site.
  -> Type           -- ^ Pi-type of bindings coming from signature site.
  -> (Telescope -> Type -> TCM a)
     -- ^ Continuation, accepting parameter telescope and rest of type.
     --   The parameters are part of the context when the continutation is invoked.
  -> TCM a

bindParameters' _ [] a ret = ret EmptyTel a

bindParameters' ts (A.DomainFull (A.TypedBindings _ (Arg info (A.TBind _ xs e))) : bs) a ret = do
  unless (null ts) __IMPOSSIBLE__
  t <- workOnTypes $ isType_ e
  bindParameters' (t <$ xs) (map (mergeHiding . fmap (A.DomainFree info)) xs ++ bs) a ret

bindParameters' _ (A.DomainFull (A.TypedBindings _ (Arg _ A.TLet{})) : _) _ _ =  -- line break!
  __IMPOSSIBLE__

bindParameters' ts0 ps0@(A.DomainFree info x : ps) t ret = do
  case ignoreSharing $ unEl t of
    -- Andreas, 2011-04-07 ignore relevance information in binding?!
    Pi arg@(Dom info' a) b -> do
      if | info == info'                  -> do
            -- Andreas, 2016-12-30, issue #1886:
            -- If type for binding is present, check its correctness.
            ts <- caseList ts0 (return []) $ \ t0 ts -> do
              equalType t0 a
              return ts
            continue ts ps x

         | visible info, notVisible info' ->
            continue ts0 ps0 =<< freshName_ (absName b)

         | otherwise                      -> __IMPOSSIBLE__
             -- Andreas, 2016-12-30 Concrete.Definition excludes this case
      where
      continue ts ps x = do
        addContext' (x, arg) $
          bindParameters' (raise 1 ts) ps (absBody b) $ \ tel s ->
            ret (ExtendTel arg $ Abs (nameToArgName x) tel) s
    _ -> __IMPOSSIBLE__


-- | Check that the arguments to a constructor fits inside the sort of the datatype.
--   The first argument is the type of the constructor.
--
--   As a side effect, return the arity of the constructor.

fitsIn :: Type -> Sort -> TCM Int
fitsIn t s = do
  reportSDoc "tc.data.fits" 10 $
    sep [ text "does" <+> prettyTCM t
        , text "of sort" <+> prettyTCM (getSort t)
        , text "fit in" <+> prettyTCM s <+> text "?"
        ]
  -- The code below would be simpler, but doesn't allow datatypes
  -- to be indexed by the universe level.
  -- s' <- instantiateFull (getSort t)
  -- noConstraints $ s' `leqSort` s
  t <- reduce t
  case ignoreSharing $ unEl t of
    Pi dom b -> do
      withoutK <- optWithoutK <$> pragmaOptions
      -- Forced constructor arguments are ignored in size-checking.
      when (withoutK || notForced (getRelevance dom)) $ do
        sa <- reduce $ getSort dom
        unless (sa == SizeUniv) $ sa `leqSort` s
      addContext (absName b, dom) $ do
        succ <$> fitsIn (absBody b) (raise 1 s)
    _ -> return 0 -- getSort t `leqSort` s  -- Andreas, 2013-04-13 not necessary since constructor type ends in data type
  where
    notForced Forced{} = False
    notForced _        = True

-- | Return the parameters that share variables with the indices
-- nonLinearParameters :: Int -> Type -> TCM [Int]
-- nonLinearParameters nPars t =

-- | Check that a type constructs something of the given datatype. The first
--   argument is the number of parameters to the datatype.
--
--   As a side effect, return the parameters that occur free in indices.
--   E.g. in @data Eq (A : Set)(a : A) : A -> Set where refl : Eq A a a@
--   this would include parameter @a@, but not @A@.
--
--   TODO: what if there's a meta here?
constructs :: Int -> Type -> QName -> TCM [Int]
constructs nofPars t q = constrT 0 t
    where
        constrT :: Nat -> Type -> TCM [Int]
        constrT n t = do
            t <- reduce t
            case ignoreSharing $ unEl t of
                Pi _ (NoAbs _ b)  -> constrT n b
                Pi a b            -> underAbstraction a b $ constrT (n + 1)
                  -- OR: addCxtString (absName b) a $ constrT (n + 1) (absBody b)
                Def d es | d == q -> do
                  let vs = fromMaybe __IMPOSSIBLE__ $ allApplyElims es
                  (pars, ixs) <- normalise $ splitAt nofPars vs
                  -- check that the constructor parameters are the data parameters
                  checkParams n pars
                  -- compute the non-linear parameters
                  m <- getContextSize  -- Note: n /= m if NoAbs encountered
                  let nl = nonLinearParams m pars ixs
                  -- assert that these are correct indices into the parameter vector
                  when (any (< 0) nl) __IMPOSSIBLE__
                  when (any (>= nofPars) nl) __IMPOSSIBLE__
                  return nl
                MetaV{} -> do
                  def <- getConstInfo q
                  xs <- newArgsMeta $ defType def
                  let t' = El (dataSort $ theDef def) $ Def q $ map Apply xs
                  equalType t t'
                  constrT n t'
                _ -> typeError $ ShouldEndInApplicationOfTheDatatype t

        checkParams n vs = zipWithM_ sameVar vs ps
            where
                nvs = size vs
                ps = genericTake nvs $ downFrom (n + nvs)

                sameVar arg i
                  -- skip irrelevant parameters
                  | isIrrelevant arg = return ()
                  | otherwise = do
                    t <- typeOfBV i
                    equalTerm t (unArg arg) (var i)

        -- return the parameters (numbered 0,1,...,size pars-1 from left to right)
        -- that occur relevantly in the indices
        nonLinearParams n pars ixs =
          -- compute the free de Bruijn indices in the data indices
          -- ALT: Ignore all sorts?
          let fv = allRelevantVarsIgnoring IgnoreInAnnotations ixs
          -- keep relevant ones, convert to de Bruijn levels
          -- note: xs is descending list
              xs = map ((n-1) -) $ VarSet.toList fv
          -- keep those that correspond to parameters
          -- in ascending list
          in  reverse $ filter (< size pars) xs

{- UNUSED, Andreas 2012-09-13
-- | Force a type to be a specific datatype.
forceData :: QName -> Type -> TCM Type
forceData d (El s0 t) = liftTCM $ do
    t' <- reduce t
    d  <- canonicalName d
    case ignoreSharing t' of
        Def d' _
            | d == d'   -> return $ El s0 t'
            | otherwise -> fail $ "wrong datatype " ++ show d ++ " != " ++ show d'
        MetaV m vs          -> do
            Defn {defType = t, theDef = Datatype{dataSort = s}} <- getConstInfo d
            ps <- newArgsMeta t
            noConstraints $ leqType (El s0 t') (El s (Def d ps)) -- TODO: need equalType?
            reduce $ El s0 t'
        _ -> typeError $ ShouldBeApplicationOf (El s0 t) d
-}

-- | Is the type coinductive? Returns 'Nothing' if the answer cannot
-- be determined.

isCoinductive :: Type -> TCM (Maybe Bool)
isCoinductive t = do
  El s t <- reduce t
  case ignoreSharing t of
    Def q _ -> do
      def <- getConstInfo q
      case theDef def of
        Axiom       {} -> return (Just False)
        Function    {} -> return Nothing
        Datatype    { dataInduction = CoInductive } -> return (Just True)
        Datatype    { dataInduction = Inductive   } -> return (Just False)
        Record      {  recInduction = Just CoInductive } -> return (Just True)
        Record      {  recInduction = _                } -> return (Just False)
        Constructor {} -> __IMPOSSIBLE__
        Primitive   {} -> __IMPOSSIBLE__
        AbstractDefn{} -> __IMPOSSIBLE__
    Var   {} -> return Nothing
    Lam   {} -> __IMPOSSIBLE__
    Lit   {} -> __IMPOSSIBLE__
    Level {} -> __IMPOSSIBLE__
    Con   {} -> __IMPOSSIBLE__
    Pi    {} -> return (Just False)
    Sort  {} -> return (Just False)
    MetaV {} -> return Nothing
    Shared{} -> __IMPOSSIBLE__
    DontCare{} -> __IMPOSSIBLE__
