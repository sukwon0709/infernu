{-# LANGUAGE DeriveFoldable    #-}
{-# LANGUAGE DeriveFunctor     #-}
{-# LANGUAGE DeriveGeneric     #-}
{-# LANGUAGE DeriveTraversable #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE TemplateHaskell   #-} -- for quickcheck all
{-# LANGUAGE TupleSections     #-}

module Types2 where

import           Control.Monad       (forM, foldM)
--import           Control.Monad.State (State, evalState, get, modify)
import           Data.Functor.Identity(Identity(..), runIdentity)
import           Control.Monad.Trans(lift)
import           Control.Monad.Trans.State (StateT(..), evalStateT, get, modify) --, EitherT(..))
import           Control.Monad.Trans.Either (EitherT(..), runEitherT, left)
import           Data.Functor        ((<$>))
import           Data.List           (intercalate)
import qualified Data.Map.Lazy       as Map
import           Data.Maybe          (fromMaybe)
import qualified Data.Set            as Set
    
-- import           Test.QuickCheck(choose)
--import           Test.QuickCheck.All    
-- import           Test.QuickCheck.Arbitrary(Arbitrary(..))
-- import           Data.DeriveTH
import Debug.Trace(traceShowId)
    
----------------------------------------------------------------------

-- var x = 2;    --> let x = ref 2 in    | x :: a
-- x = 3;        -->   x := 3            |

-- var f = function (x) { return [x]; }    --> let f = ref (\x -> arr [x])  :: Ref (forall a. a -> [a])
-- var g = f;                              -->     g = ref (!f)             :: Ref (forall a. a -> [a])
-- var st = f('abc');                      -->     st = ref (!f 'abc')      :: Ref [String]
-- var num = f(1234);                      -->     num = ref (!f 1234)      :: Ref [Number]

----------------------------------------------------------------------

type EVarName = String

data LitVal = LitNumber Double | LitBoolean Bool | LitString String
            deriving (Show, Eq, Ord)

data Exp = EVar EVarName
         | EApp Exp Exp
         | EAbs EVarName Exp
         | ELet EVarName Exp Exp
         | ELit LitVal
         | EAssign EVarName Exp Exp
         | EArray [Exp]
         | ETuple [Exp]
         deriving (Show, Eq, Ord)

----------------------------------------------------------------------

type TVarName = Int


data TBody = TVar TVarName
            | TNumber | TBoolean | TString
            deriving (Show, Eq, Ord)

data TConsName = TFunc | TArray | TTuple
            deriving (Show, Eq, Ord)
               
data Type t = TBody t
            | TCons TConsName [Type t]
            deriving (Show, Eq, Ord, Functor)--, Foldable, Traversable)


type TSubst = Map.Map TVarName (Type TBody)


----------------------------------------------------------------------

class Types a where
  freeTypeVars :: a -> Set.Set TVarName
  applySubst :: TSubst -> a -> a

-- for convenience only:
instance Types a => Types [a] where
  freeTypeVars = Set.unions . map freeTypeVars
  applySubst s = map (applySubst s)

instance Types a => Types (Map.Map b a) where
  freeTypeVars m = freeTypeVars . Map.elems $ m
  applySubst s = Map.map (applySubst s)
  
----------------------------------------------------------------------

instance Types (Type TBody) where
  freeTypeVars (TBody (TVar n)) = Set.singleton n
  freeTypeVars (TBody _) = Set.empty
  freeTypeVars (TCons _ ts) = Set.unions $ map freeTypeVars ts

  applySubst s t@(TBody (TVar n)) = fromMaybe t $ Map.lookup n s
  applySubst _ t@(TBody _) = t
  applySubst s (TCons n ts) = TCons n (applySubst s ts)
                                     
----------------------------------------------------------------------

-- | Type scheme: a type expression with a "forall" over some type variables that may appear in it (universal quantification).
data TScheme = TScheme [TVarName] (Type TBody)
             deriving (Show, Eq)

instance Types TScheme where
  freeTypeVars (TScheme qvars t) = freeTypeVars t `Set.difference` Set.fromList qvars
  applySubst s (TScheme qvars t) = TScheme qvars $ applySubst (foldr Map.delete s qvars) t

alphaEquivalent :: TScheme -> TScheme -> Bool                                   
alphaEquivalent ts1@(TScheme tvn1 _) (TScheme tvn2 t2) = ts1 == TScheme tvn1 ts2'
    where TScheme _ ts2' = applySubst substVarNames (TScheme [] t2)
          substVarNames = Map.fromList . map (\(old,new) -> (old, TBody $ TVar new)) $ zip tvn2 tvn1
    
----------------------------------------------------------------------

-- | Type environment: maps AST variables (not type variables!) to quantified type schemes.
--
-- Note: instance of Types 
type TypeEnv = Map.Map EVarName TScheme

-- Used internally to generate fresh type variable names
data NameSource = NameSource { lastName :: TVarName }
                deriving (Show, Eq)


----------------------------------------------------------------------

nullSubst :: TSubst
nullSubst = Map.empty

-- | composeSubst should obey the law:
-- applySubst (composeSubst new old) t = applySubst new (applySubst old t)
composeSubst :: TSubst -> TSubst -> TSubst
composeSubst new old = applySubst new old `Map.union` new

singletonSubst :: TVarName -> Type TBody -> TSubst
singletonSubst = Map.singleton

prop_composeSubst :: TSubst -> TSubst -> Type TBody -> Bool
prop_composeSubst new old t = applySubst (composeSubst new old) t == applySubst new (applySubst old t)

----------------------------------------------------------------------

-- | Inference monad. Used as a stateful context for generating fresh type variable names.
type Infer a = StateT NameSource (EitherT String Identity) a

runInferWith :: NameSource -> Infer a -> Either String a
runInferWith ns inf = runIdentity . runEitherT $ evalStateT inf ns

runInfer :: Infer a -> Either String a
runInfer = runInferWith NameSource { lastName = 0 }

fresh :: Infer TVarName
fresh = do
  modify (\ns -> ns { lastName = lastName ns + 1 })
  lastName <$> get

throwError :: String -> Infer a
throwError = lift . left

-- | Instantiate a type scheme by giving fresh names to all quantified type variables.
--
-- For example:
--
-- >>> runInferWith (NameSource 2) . instantiate $ TScheme [0] (TCons TFunc [TBody (TVar 0), TBody (TVar 1)])
-- Right (TCons TFunc [TBody (TVar 3),TBody (TVar 1)])
--
-- In the above example, type variable 0 has been replaced with a fresh one (3), while the unqualified free type variable 1 has been left as-is.
--
instantiate :: TScheme -> Infer (Type TBody)
instantiate (TScheme tvarNames t) = do
  allocNames <- forM tvarNames $ \tvName -> do
    freshName <- fresh
    return (tvName, freshName)

  let replaceVar (TVar n) = TVar . fromMaybe n $ lookup n allocNames
      replaceVar x = x

  return $ fmap replaceVar t

----------------------------------------------------------------------
-- | Generalizes a type to a type scheme, i.e. wraps it in a "forall" that quantifies over all
--   type variables that are free in the given type, but are not free in the type environment.
--
-- Example:
--
-- >>> let t = TScheme [0] (TCons TFunc [TBody (TVar 0), TBody (TVar 1)])
-- >>> let tenv = Map.insert "x" t Map.empty
-- >>> tenv
-- fromList [("x",TScheme [0] (TCons TFunc [TBody (TVar 0),TBody (TVar 1)]))]
-- >>> generalize tenv (TCons TFunc [TBody (TVar 1), TBody (TVar 2)])
-- TScheme [2] (TCons TFunc [TBody (TVar 1),TBody (TVar 2)])
--
-- In this example the steps were:
--
-- 1. Environment: { x :: forall 0. 0 -> 1 }
--
-- 2. generalize (1 -> 2)
--
-- 3. result: forall 2. 1 -> 2
--
-- >>> generalize Map.empty (TCons TFunc [TBody (TVar 0), TBody (TVar 0)])
-- TScheme [0] (TCons TFunc [TBody (TVar 0),TBody (TVar 0)])
--
generalize :: TypeEnv -> Type TBody -> TScheme
generalize tenv t = TScheme (Set.toList (freeTypeVars t `Set.difference` freeTypeVars tenv)) t

----------------------------------------------------------------------

unify :: Type TBody -> Type TBody -> Infer TSubst
unify (TBody (TVar n)) t = varBind n t
unify t (TBody (TVar n)) = varBind n t
unify (TBody x) (TBody y) = if x == y
                            then return nullSubst
                            else throwError $ "Could not unify: " ++ pretty x ++ " with " ++ pretty y
unify t1@(TBody _) t2@(TCons _ _) = throwError $ "Could not unify: " ++ pretty t1 ++ " with " ++ pretty t2
unify t1@(TCons _ _) t2@(TBody _) = unify t2 t1
unify (TCons n1 ts1) (TCons n2 ts2) =
    if (n1 == n2) && (length ts1 == length ts2)
    then unifyl nullSubst ts1 ts2
    else throwError $ "TCons names or number of parameters do not match: " ++ pretty n1 ++ " /= " ++ pretty n2

unifyl :: TSubst -> [Type TBody] -> [Type TBody] -> Infer TSubst
unifyl initialSubst xs ys = foldM unifyl' initialSubst $ zip xs ys
    where unifyl' s (x, y) = do
            s' <- unify (applySubst s x) (applySubst s y)
            return $ s' `composeSubst` s

varBind :: TVarName -> Type TBody -> Infer TSubst
varBind n t | t == TBody (TVar n) = return nullSubst
            | n `Set.member` freeTypeVars t = throwError $ "Occurs check failed: " ++ pretty n ++ " in " ++ pretty t
            | otherwise = return $ singletonSubst n t


                          
----------------------------------------------------------------------

accumInfer :: TypeEnv -> [Exp] -> Infer (TSubst, TypeEnv, [Type TBody])
accumInfer env = foldM accumInfer' (nullSubst, env, [])
    where accumInfer' (subst, env', types) expr = do
            (subst', t) <- inferType env' expr
            return (subst' `composeSubst` subst, applySubst subst' env, t:types)

inferType :: TypeEnv -> Exp -> Infer (TSubst, Type TBody)
inferType _ (ELit lit) = return . (nullSubst,) $ TBody $ case lit of
  LitNumber _ -> TNumber
  LitBoolean _ -> TBoolean
  LitString _ -> TString
inferType env (EVar n) = case Map.lookup n env of
  Nothing -> throwError $ "Unbound variable: " ++ n
  Just ts -> (nullSubst,) <$> instantiate ts
inferType env (EAbs argName e2) =
  do tvarName <- fresh
     let tvar = TBody (TVar tvarName)
         env' = Map.insert argName (TScheme [] tvar) env
     (s1, t1) <- inferType env' e2
     return (s1, TCons TFunc [applySubst s1 tvar, t1])
inferType env (EApp e1 e2) =
  do tvarName <- fresh
     let tvar = TBody (TVar tvarName)
     (s1, t1) <- inferType env e1
     (s2, t2) <- inferType (applySubst s1 env) e2
     s3 <- unify (applySubst s2 t1) (TCons TFunc [t2, tvar])
     return (s3 `composeSubst` s2 `composeSubst` s1, applySubst s3 tvar)
inferType env (ELet n e1 e2) =
  do (s1, t1) <- inferType env e1
     let t' = generalize (applySubst s1 env) t1
         env' = Map.insert n t' env
     (s2, t2) <- inferType env' e2
     return (s2 `composeSubst` s1, t2)
inferType env (EAssign n e1 e2) =
  do (s1, t1) <- inferType env e1
     -- TODO fix.
     -- TODO consider: let x = \y -> y in x := \y -> 0;
     -- in the assignment, a -> Int will be unified with instance of forall a. a -> a (which is b -> b).
     -- so b = a, and b = Int, and it will succeed unification, even though \y -> 0 is not as general as \y -> y
     -- which shows that unification as above is not enough to avoid a bug.
     -- TODO consider also: let x = \y -> 0 in x := \y -> y;
     -- in this case, a -> Int is unified with b -> b (but the other way around) and
     -- thus again b = a, b = Int. In this case we want the \y -> y to have type :: Int -> Int, otherwise
     -- the types are wrong again.
     --let ts1 = generalize (applySubst s1 env) t1
     case Map.lookup n env of
       Nothing -> throwError $ "Unbound variable: " ++ n
       Just ts2 -> do t2 <- instantiate ts2
                      s2 <- unify t1 $ applySubst s1 t2
                      let s3 = s2 `composeSubst` s1
                          env' = applySubst s3 env
                          env'' = Map.insert n (generalize env' $ applySubst s3 t1) env'
                      inferType env'' e2
                      
inferType env (EArray exprs) =
  do tvName <- fresh
     let tv = TBody $ TVar tvName
     (subst, _, types) <- accumInfer env exprs
     subst' <- unifyl subst (tv:types) types
     return (subst', TCons TArray [applySubst subst' $ TBody $ TVar tvName])
inferType env (ETuple exprs) =
  do (subst, _, types) <- accumInfer env exprs
     return (subst, TCons TTuple types)
    
typeInference :: TypeEnv -> Exp -> Infer (Type TBody)
typeInference env e = do
  (s, t) <- inferType env e
  return $ applySubst s t

----------------------------------------------------------------------

class Pretty a where
  pretty :: a -> String

instance Pretty LitVal where
  pretty (LitNumber x) = show x
  pretty (LitBoolean x) = show x
  pretty (LitString x) = show x

instance Pretty EVarName where
  pretty x = x

instance Pretty Exp where
  pretty (EVar n) = pretty n
  pretty (EApp e1 e2) = pretty e1 ++ " " ++ pretty e2
  pretty (EAbs n e) = "(\\" ++ pretty n ++ " -> " ++ pretty e ++ ")"
  pretty (ELet n e1 e2) = "(let " ++ pretty n ++ " = " ++ pretty e1 ++ " in " ++ pretty e2 ++ ")"
  pretty (ELit l) = pretty l
  pretty (EAssign n e1 e2) = pretty n ++ " := " ++ pretty e1 ++ "; " ++ pretty e2
  pretty (EArray es) = "[" ++ intercalate ", " (map pretty es) ++ "]"
  pretty (ETuple es) = "(" ++ intercalate ", " (map pretty es) ++ ")"
                       
instance Pretty TVarName where
  pretty = show

instance Pretty TBody where
  pretty (TVar n) = pretty n
  pretty x = show x

instance Pretty TConsName where
  pretty = show
            
instance Pretty t => Pretty (Type t) where
  pretty (TBody t) = pretty t
  pretty (TCons TFunc [t1, t2]) = pretty t1 ++ " -> " ++ pretty t2
  pretty (TCons TArray [t]) = "[" ++ pretty t ++ "]"
  pretty (TCons TTuple ts) = "(" ++ intercalate ", " (map pretty ts) ++ ")"
  pretty _ = error "Unknown type for pretty"
             
instance Pretty TScheme where
  pretty (TScheme vars t) = forall ++ pretty t
      where forall = if null vars then "" else "forall " ++ unwords (map pretty vars) ++ ". "

instance (Pretty a, Pretty b) => Pretty (Either a b) where
    pretty (Left x) = "Error: " ++ pretty x
    pretty (Right x) = pretty x

----------------------------------------------------------------------

-- | 'test' is a utility function for running the following tests:
--
-- >>> test $ ETuple [ELit (LitBoolean True), ELit (LitNumber 2)]
-- Right (TCons TTuple [TBody TNumber,TBody TBoolean])
--
-- >>> test $ ELet "id" (EAbs "x" (EVar "x")) (EAssign "id" (EAbs "y" (EVar "y")) (EVar "id"))
-- Right (TCons TFunc [TBody (TVar 4),TBody (TVar 4)])
--
-- >>> test $ ELet "id" (EAbs "x" (EVar "x")) (EAssign "id" (ELit (LitBoolean True)) (EVar "id"))
-- Left "Could not unify: TBoolean with 2 -> 2"
--
-- >>> test $ ELet "x" (ELit (LitBoolean True)) (EAssign "x" (ELit (LitBoolean False)) (EVar "x"))
-- Right (TBody TBoolean)
--
-- >>> test $ ELet "x" (ELit (LitBoolean True)) (EAssign "x" (ELit (LitNumber 3)) (EVar "x"))
-- Left "Could not unify: TNumber with TBoolean"
--
-- >>> test $ ELet "x" (EArray [ELit $ LitBoolean True]) (EVar "x")
-- Right (TCons TArray [TBody TBoolean])
--
-- >>> test $ ELet "x" (EArray [ELit $ LitBoolean True, ELit $ LitBoolean False]) (EVar "x")
-- Right (TCons TArray [TBody TBoolean])
--
-- >>> test $ ELet "x" (EArray []) (EAssign "x" (EArray []) (EVar "x"))
-- Right (TCons TArray [TBody (TVar 4)])
--
-- >>> test $ ELet "x" (EArray [ELit $ LitBoolean True, ELit $ LitNumber 2]) (EVar "x")
-- Left "Could not unify: TNumber with TBoolean"
--
-- >>> test $ ELet "id" (EAbs "x" (ELet "y" (EVar "x") (EVar "y"))) (EApp (EVar "id") (EVar "id"))
-- Right (TCons TFunc [TBody (TVar 4),TBody (TVar 4)])
--
-- >>> test $ ELet "id" (EAbs "x" (ELet "y" (EVar "x") (EVar "y"))) (EApp (EApp (EVar "id") (EVar "id")) (ELit (LitNumber 2)))
-- Right (TBody TNumber)
--
-- >>> test $ ELet "id" (EAbs "x" (EApp (EVar "x") (EVar "x"))) (EVar "id")
-- Left "Occurs check failed: 1 in 1 -> 2"
--
-- >>> test $ EAbs "m" (ELet "y" (EVar "m") (ELet "x" (EApp (EVar "y") (ELit (LitBoolean True))) (EVar "x")))
-- Right (TCons TFunc [TCons TFunc [TBody TBoolean,TBody (TVar 2)],TBody (TVar 2)])
--
-- >>> test $ EApp (ELit (LitNumber 2)) (ELit (LitNumber 2))
-- Left "Could not unify: TNumber with TNumber -> 1"
--
-- >>> test $ ELet "x" (EAbs "y" (ELit (LitNumber 0))) (EAssign "x" (EAbs "y" (EVar "y")) (EVar "x"))
-- Right (TCons TFunc [TBody TNumber,TBody TNumber])
--
-- >>> test $ ELet "x" (EAbs "y" (EVar "y")) (EAssign "x" (EAbs "y" (ELit (LitNumber 0))) (EVar "x"))
-- Right (TCons TFunc [TBody TNumber,TBody TNumber])
--
-- >>> test $ ELet "x" (EAbs "y" (EVar "y")) (ETuple [EApp (EVar "x") (ELit (LitNumber 2)), EApp (EVar "x") (ELit (LitBoolean True))])
-- Right (TCons TTuple [TBody TBoolean,TBody TNumber])
--
test :: Exp -> Either String (Type TBody)
test e = runInfer $ typeInference Map.empty e
         --in pretty e ++ " :: " ++ pretty t ++ "\n"
--     case res of
--       Left err -> putStrLn $ show e ++ "\n " ++ err ++ "\n"
--       Right t -> putStrLn $ show e ++ " :: " ++ show t ++ "\n"
    

-- Test runner

--return []

-- $( derive makeArbitrary ''TBody )
-- $( derive makeArbitrary ''Type )

--runAllTests = $(quickCheckAll)
       