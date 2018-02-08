{-# LANGUAGE LambdaCase, RecordWildCards #-}
module AbstractInterpretation.CodeGen
  ( codeGen
  , Env(..)
  , HPTProgram
  ) where

import Data.Word
import qualified Data.Bimap as Bimap
import qualified Data.Map as Map
import Control.Monad.State
import Data.Functor.Foldable as Foldable

import Grin
import qualified AbstractInterpretation.IR as IR

type HPTProgram = Env

data Env
  = Env
  { envMemoryCounter    :: Word32
  , envRegisterCounter  :: Word32
  , envRegisterMap      :: Bimap.Bimap Name IR.Reg
  , envInstructions     :: [IR.Instruction]
  , envFunctionArgMap   :: Map.Map Name (IR.Reg, [IR.Reg])
  , envTagMap           :: Bimap.Bimap Tag IR.Tag
  }

emptyEnv = Env
  { envMemoryCounter    = 0
  , envRegisterCounter  = 0
  , envRegisterMap      = Bimap.empty
  , envInstructions     = []
  , envFunctionArgMap   = Map.empty
  , envTagMap           = Bimap.empty
  }

type CG = State Env

data Result
  = R IR.Reg
  | Z
  | A CPat (CG Result)


emit :: IR.Instruction -> CG ()
emit inst = modify' $ \s@Env{..} -> s {envInstructions = inst : envInstructions}

{-
  Unit      -1
  Int       -2
  Word      -3
  Float     -4
  Bool      -5
  Undefined -9999
-}

{-
 CONSTANT value building operations (from compile time constants)
  add simple type
  add heap location
  add node type (tag + arity)
  add node item (index + location or simple type)
-}

-- creates regsiters for function arguments and result
getOrAddFunRegs :: Name -> Int -> CG (IR.Reg, [IR.Reg])
getOrAddFunRegs name arity = do
  funMap <- gets envFunctionArgMap
  case Map.lookup name funMap of
    Just x  -> pure x
    Nothing -> do
      resReg <- newReg
      argRegs <- replicateM arity newReg
      let funRegs = (resReg, argRegs)
      modify' $ \s@Env{..} -> s {envFunctionArgMap = Map.insert name funRegs envFunctionArgMap}
      pure funRegs

newReg :: CG IR.Reg
newReg = state $ \s@Env{..} -> (IR.Reg envRegisterCounter, s {envRegisterCounter = succ envRegisterCounter})

newMem :: CG IR.Mem
newMem = state $ \s@Env{..} -> (IR.Mem envMemoryCounter, s {envMemoryCounter = succ envMemoryCounter})

addReg :: Name -> IR.Reg -> CG ()
addReg name reg = modify' $ \s@Env{..} -> s {envRegisterMap = Bimap.insert name reg envRegisterMap}

getReg :: Name -> CG IR.Reg
getReg name = do
  regMap <- gets envRegisterMap
  case Bimap.lookup name regMap of
    Nothing   -> error $ "unknown variable " ++ name
    Just reg  -> pure reg

getTag :: Tag -> CG IR.Tag
getTag tag = do
  tagMap <- gets envTagMap
  case Bimap.lookup tag tagMap of
    Just t  -> pure t
    Nothing -> do
      let t = IR.Tag . fromIntegral $ Bimap.size tagMap
      modify' $ \s -> s {envTagMap = Bimap.insert tag t tagMap}
      pure t

litToSimpleType :: Lit -> IR.SimpleType
litToSimpleType = \case
  LInt64  {}  -> -2
  LWord64 {}  -> -3
  LFloat  {}  -> -4
  LBool   {}  -> -5

codeGenVal :: Val -> CG IR.Reg
codeGenVal = \case
  ConstTagNode tag vals -> do
    r <- newReg
    irTag <- getTag tag
    emit $ IR.Init {dstReg = r, constant = IR.CNodeType irTag (length vals)}
    forM_ (zip [0..] vals) $ \(idx, val) -> case val of
      Var name -> do
        valReg <- getReg name
        emit $ IR.Extend {srcReg = valReg, dstSelector = IR.NodeItem irTag idx, dstReg = r}
      Lit lit -> emit $ IR.Init {dstReg = r, constant = IR.CNodeItem irTag idx (litToSimpleType lit)}
      _ -> error $ "illegal node item value " ++ show val
    pure r
  Unit -> do
    r <- newReg
    emit $ IR.Init {dstReg = r, constant = IR.CSimpleType (-1)}
    pure r
  Lit lit -> do
    r <- newReg
    emit $ IR.Init
      { dstReg    = r
      , constant  = IR.CSimpleType (litToSimpleType lit)
      }
    pure r
  Var name -> getReg name
  val -> error $ "unsupported value " ++ show val

registerPrimOps :: CG Result
registerPrimOps = do
  let regOp name arity ty = do
        (funResultReg, _) <- getOrAddFunRegs name arity
        emit $ IR.Init {dstReg = funResultReg, constant = IR.CSimpleType (litToSimpleType ty)}

      int   = LInt64 0
      word  = LWord64 0
      float = LFloat 0
      bool  = LBool False

  -- Int
  regOp "_prim_int_add"   2 int
  regOp "_prim_int_sub"   2 int
  regOp "_prim_int_mul"   2 int
  regOp "_prim_int_div"   2 int
  regOp "_prim_int_eq"    2 bool
  regOp "_prim_int_ne"    2 bool
  regOp "_prim_int_gt"    2 bool
  regOp "_prim_int_ge"    2 bool
  regOp "_prim_int_lt"    2 bool
  regOp "_prim_int_le"    2 bool
  -- Word
  regOp "_prim_word_add"  2 word
  regOp "_prim_word_sub"  2 word
  regOp "_prim_word_mul"  2 word
  regOp "_prim_word_div"  2 word
  regOp "_prim_word_eq"   2 bool
  regOp "_prim_word_ne"   2 bool
  regOp "_prim_word_gt"   2 bool
  regOp "_prim_word_ge"   2 bool
  regOp "_prim_word_lt"   2 bool
  regOp "_prim_word_le"   2 bool
  -- Float
  regOp "_prim_float_add" 2 float
  regOp "_prim_float_sub" 2 float
  regOp "_prim_float_mul" 2 float
  regOp "_prim_float_div" 2 float
  regOp "_prim_float_eq"  2 bool
  regOp "_prim_float_ne"  2 bool
  regOp "_prim_float_gt"  2 bool
  regOp "_prim_float_ge"  2 bool
  regOp "_prim_float_lt"  2 bool
  regOp "_prim_float_le"  2 bool
  -- Bool
  regOp "_prim_bool_eq"   2 bool
  regOp "_prim_bool_ne"   2 bool

  pure Z

codeGen :: Exp -> Env
codeGen = flip execState emptyEnv . cata folder where
  folder :: ExpF (CG Result) -> CG Result
  folder = \case
    ProgramF defs -> sequence_ defs >> registerPrimOps

    DefF name args body -> do
      instructions <- state $ \s@Env{..} -> (envInstructions, s {envInstructions = []})
      (funResultReg, funArgRegs) <- getOrAddFunRegs name $ length args
      zipWithM addReg args funArgRegs
      body >>= \case
        Z   -> pure ()
        R r -> emit $ IR.Move {srcReg = r, dstReg = funResultReg}
      modify' $ \s@Env{..} -> s {envInstructions = reverse envInstructions ++ instructions}
      pure Z

    EBindF leftExp lpat rightExp -> do
      leftExp >>= \case
        Z -> case lpat of
          Unit -> pure ()
          _ -> error $ "pattern mismatch at HPT bind codegen, expected Unit got " ++ show lpat
        R r -> case lpat of -- QUESTION: should the evaluation continue if the pattern does not match yet?
          Unit  -> pure () -- TODO: is this ok? or error?
          Lit{} -> pure () -- TODO: is this ok? or error?
          Var name -> addReg name r
          ConstTagNode tag args -> do
            irTag <- getTag tag
            bindInstructions <- forM (zip [0..] args) $ \(idx, arg) -> case arg of
              Var name -> do
                argReg <- newReg
                addReg name argReg
                pure [IR.Project {srcSelector = IR.NodeItem irTag idx, srcReg = r, dstReg = argReg}]
              Lit {} -> pure []
              _ -> error $ "illegal node pattern component " ++ show arg
            emit $ IR.If
              { condition     = IR.NodeTypeExists irTag
              , srcReg        = r
              , instructions  = concat bindInstructions
              }
          _ -> error $ "unsupported lpat " ++ show lpat
      rightExp

    ECaseF val alts -> do
      valReg <- codeGenVal val
      caseResultReg <- newReg
      forM_ alts $ \alt -> do
        (A cpat altM) <- alt
        case cpat of
          NodePat tag vars -> do
            irTag <- getTag tag
            ----------- BEGIN ; FIXME
            -- save instructions, clear, join altM, read instructions, swap saved instructions back
            instructions <- state $ \s@Env{..} -> (envInstructions, s {envInstructions = []})
            -- bind pattern variables
            forM_ (zip [0..] vars) $ \(idx, name) -> do
                argReg <- newReg
                addReg name argReg
                emit $ IR.Project {srcSelector = IR.NodeItem irTag idx, srcReg = valReg, dstReg = argReg}
            altRes <- altM
            case altRes of
              Z -> pure ()
              R altResultReg -> emit $ IR.Move {srcReg = altResultReg, dstReg = caseResultReg}
            altInstructions <- state $ \s@Env{..} -> (reverse envInstructions, s {envInstructions = instructions})
            ----------- END
            emit $ IR.If {condition = IR.NodeTypeExists irTag, srcReg = valReg, instructions = altInstructions}
          LitPat lit -> do
            ----------- BEGIN ; FIXME
            -- save instructions, clear, join altM, read instructions, swap saved instructions back
            instructions <- state $ \s@Env{..} -> (envInstructions, s {envInstructions = []})
            altRes <- altM -- FIXME: move after pattern variable binding
            case altRes of
              Z -> pure ()
              R altResultReg -> emit $ IR.Move {srcReg = altResultReg, dstReg = caseResultReg}
            altInstructions <- state $ \s@Env{..} -> (reverse envInstructions, s {envInstructions = instructions})
            ----------- END
            emit $ IR.If {condition = IR.SimpleTypeExists (litToSimpleType lit), srcReg = valReg, instructions = altInstructions}
          _ -> error $ "HPT does not support the following case pattern: " ++ show cpat
      pure $ R caseResultReg

    AltF cpat exp -> pure $ A cpat exp

    SAppF name args -> do -- copy args to definition's variables ; read function result register
      (funResultReg, funArgRegs) <- getOrAddFunRegs name $ length args
      valRegs <- mapM codeGenVal args
      zipWithM (\src dst -> emit $ IR.Move {srcReg = src, dstReg = dst}) valRegs funArgRegs
      pure $ R funResultReg

    SReturnF val -> R <$> codeGenVal val

    SStoreF val -> do
      loc <- newMem
      r <- newReg
      valReg <- codeGenVal val
      emit $ IR.Store {srcReg = valReg, address = loc}
      emit $ IR.Init {dstReg = r, constant = IR.CHeapLocation loc}
      pure $ R r

    SFetchIF name maybeIndex -> case maybeIndex of
      Just {} -> error "HPT codegen does not support indexed fetch"
      Nothing -> do
        addressReg <- getReg name
        r <- newReg
        emit $ IR.Fetch {addressReg = addressReg, dstReg = r}
        pure $ R r

    SUpdateF name val -> do
      addressReg <- getReg name
      valReg <- codeGenVal val
      emit $ IR.Update {srcReg = valReg, addressReg = addressReg}
      pure Z

    SBlockF exp -> exp

{-
  >>= LPAT
    (Tag b c d)               - node only check, arity check, tag check, copy node items to registers for a specific tag
    Unit                      - specific simple type only check
    Literal with simple type  - specific simple type only check
    variable                  - copy to reg

  case >>= LPAT ()
  return >>= LPAT ()
  store >>= LPAT
  fetch >>= LPAT
  update >>= LPAT

  LPAT / VAL
  T a - select items of specific tag
  Unit- NOP ; optional check
  Lit - NOP ; optional check
  a   - copy all


 bind COMPILE TIME CHECK:
  VAL / LPAT
  T a - T a   OK      (node)
      - Unit  FAIL
      - Lit   FAIL
      - a     OK

  Unit- T a   FAIL    (simple type)
      - Unit  OK
      - Lit   FAIL
      - a     OK

  Lit - T a   FAIL    (simple type)
      - Unit  FAIL
      - Lit   OK ; if matches
      - a     OK

  a   - T a   OK      (any)
      - Unit  OK
      - Lit   OK
      - a     OK

  LOC - T a   FAIL    (heap location)
      - Unit  FAIL
      - Lit   FAIL
      - a     OK

  compilation:
    store (the only valid expression): store VAL >>= var
      emits:
        one time constant register setup for var
        memory copy or one time setup
        VAL validation
    update DST VAL >>= (var | Unit)
      VAL validation
      DST validaton
      var: emits one time setup for var ; fill with Unit type
      Unit: nothing to do
    fetch SRC >>= (var | (T a) | (t a))
      SRC validation
      var: CopyMemReg
      (T a): 

-}

{-
 case COMPILE TIME CHECK:
  VAL / CPAT
  T a - T a   OK      (node)
      - Lit   FAIL

  Unit- T a   FAIL    (simple type)
      - Lit   FAIL

  Lit - T a   FAIL    (simple type)
      - Lit   OK ; if matches

  a   - T a   OK      (any)
      - Lit   OK

  LOC - T a   FAIL    (heap location)
      - Lit   FAIL
-}