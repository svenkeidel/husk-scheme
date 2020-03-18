{- |
Module      : Language.Scheme.Macro.ExplicitRenaming
Copyright   : Justin Ethier
Licence     : MIT (see LICENSE in the distribution)

Maintainer  : github.com/justinethier
Stability   : experimental
Portability : portable

This module contains code for explicit renaming (ER) macros, and is
used by the Macro module to provide support for ER macros, both when 
called directly or when ER macros are found during macro expansion. 
This ensures both the er-macro-transformer and syntax-rules systems 
are compatible with each other.

Explicit renaming macros are based on the low-level facility from
Will Clinger's paper "Hygienic Macros Through Explicit Renaming",
which was developed to complement the high level specification
language (syntax-rules) from "Macros that Work".

-}

module Language.Scheme.Macro.ExplicitRenaming
    (
      explicitRenamingTransform
    ) where
import Language.Scheme.Types
import Language.Scheme.Variables
import Language.Scheme.Primitives (_gensym)
import Control.Monad.Except
-- import Debug.Trace

-- |Handle an explicit renaming macro
explicitRenamingTransform :: 
       Env -- ^Environment where macro was used
    -> Env -- ^Temporary environment to store renamed variables
    -> Env -- ^Environment containing any variables renamed by syntax-rules
    -> LispVal -- ^Form to transform
    -> LispVal -- ^Macro transformer
    -> (LispVal -> LispVal -> [LispVal] -> IOThrowsError LispVal) -- ^Eval func
    -> IOThrowsError LispVal
explicitRenamingTransform useEnv renameEnv srRenameEnv lisp 
                          transformer@(Func _ _ _ defEnv) apply = do
  let continuation = makeNullContinuation useEnv
  result <- apply 
    continuation
    transformer
    [lisp, 
     IOFunc $ exRename useEnv renameEnv srRenameEnv defEnv, 
     IOFunc $ exCompare useEnv renameEnv defEnv] 
  recDerefPtrs result
explicitRenamingTransform _ _ _ _ _ _ = 
  throwError $ InternalError "explicitRenamingTransform"

-- |The explicit renaming /rename/ function
--
-- From clinger's paper "Hygienic Macros Through Explicit Renaming":
--
-- The expression returned by the transformation procedure
-- will be expanded in the syntactic environment obtained
-- from the syntactic environment of the macro application
-- by binding any fresh identifiers in the syntactic
-- environment in which the macro was defined. This means
-- that a renamed identifier will denote the same thing as
-- the original identifier unless the transformation
-- procedure that renamed the identifier placed an
-- occurrence of it in a binding position.
--
-- The renaming procedure acts as a mathematical function
-- in the sense that the idenfiers obtained from any two
-- calls with the same argument will be the same in
-- the sense of eqv?. It is an error if the renaming
-- procedure is called after the transformation
-- procedure has returned.
exRename :: Env -> Env -> Env -> Env -> [LispVal] -> IOThrowsError LispVal
exRename useEnv _ srRenameEnv defEnv [Atom a] = do
  isSynRulesRenamed <- liftIO $ isRecBound srRenameEnv a

  if isSynRulesRenamed -- already renamed by syntax-rules, so just return it
   then getVar srRenameEnv a
   else do
    isDef <- liftIO $ isRecBound defEnv a
    if isDef
     then do

       -- NOTE: useEnv/'r' is used to store renamed variables due
       --       to issues with separate invocations of er macros
       --       renaming the same variable differently within the
       --       same context. This caused the module meta language
       --       to not work properly...
       r <- getNamespacedVar' useEnv 'r' a
       case r of
         Just renamed -> return renamed
         Nothing -> do
            value <- getVar defEnv a
            Atom renamed <- _gensym a -- Unique name
            _ <- defineVar useEnv renamed value -- divert value to Use Env
            _ <- defineNamespacedVar useEnv 'r' a $ Atom renamed -- Record renamed sym

            -- Keep track of diverted values for use by the compiler
            List diverted <- getNamespacedVar useEnv ' ' "diverted"
            _ <- setNamespacedVar useEnv ' ' "diverted" $ 
                List (diverted ++ [List [Atom renamed, Atom a]])

            return $ Atom renamed
     else
       return $ Atom a
exRename _ _ _ _ form = throwError $ Default $ "Unable to rename: " ++ show form

-- |The explicit renaming /compare/ function
exCompare :: Env        -- ^ Environment of use
          -> Env        -- ^ Environment with renames
          -> Env        -- ^ Environment of definition
          -> [LispVal]  -- ^ Values to compare
          -> IOThrowsError LispVal
exCompare _ _ _ [a, b] = do
  return $ Bool $ eqVal a b
exCompare _ _ _ form = throwError $ 
   Default $ "Unable to compare: " ++ show form

