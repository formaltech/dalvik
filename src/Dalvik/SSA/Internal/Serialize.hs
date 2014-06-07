{-# LANGUAGE BangPatterns #-}
{-# LANGUAGE ViewPatterns #-}
module Dalvik.SSA.Internal.Serialize (
  deserializeDex,
  serializeDex
  ) where

import Control.Applicative
import Control.Arrow ( second )
import qualified Data.ByteString as BS
import qualified Data.Foldable as F
import qualified Data.HashMap.Strict as HM
import qualified Data.List.NonEmpty as NEL
import Data.Map ( Map )
import qualified Data.Map as M
import Data.Maybe ( fromMaybe, maybeToList )
import qualified Data.Serialize as S
import qualified Data.Set as Set
import qualified Data.Vector as V

import Dalvik.SSA.Internal.Pretty ()
import Dalvik.SSA.Types

import Debug.Trace
debug = flip trace

deserializeDex :: BS.ByteString -> Either String DexFile
deserializeDex bs =
  let getKnot = snd . either error id
      res = S.runGet (getDex (getKnot res)) bs
  in case res of
    Left err -> Left err
    Right (df, _) -> Right df

data Knot = Knot { knotTypeTable :: !(Map Int Type)
                 , knotClasses :: !(Map Int Class)
                 , knotMethods :: !(Map Int Method)
                 , knotValues :: !(Map Int Value)
                 , knotBlocks :: !(Map Int BasicBlock)
                 , knotMethodRefs :: !(Map Int MethodRef)
                 , knotFields :: !(Map Int Field)
                 }

emptyKnot :: Knot
emptyKnot = Knot { knotTypeTable = M.empty
                 , knotClasses = M.empty
                 , knotMethods = M.empty
                 , knotValues = M.empty
                 , knotBlocks = M.empty
                 , knotMethodRefs = M.empty
                 , knotFields = M.empty
                 }

serializeDex :: DexFile -> BS.ByteString
serializeDex = S.runPut . putDex

-- | Format:
--
-- Int (id source)
-- Type list
-- Constant list
-- Field list
-- Method ref list
-- Class list
putDex :: DexFile -> S.Put
putDex df = do
  S.put (dexIdSrc df)
  tt <- putTypeTable (dexTypes df)
  putList (putConstant tt) (dexConstants df)
  putList (putField tt) (dexFields df)
  putList (putMethodRef tt) (dexMethodRefs df)
  putList (putClass tt) (dexClasses df)

getDex :: Knot -> S.Get (DexFile, Knot)
getDex fknot = do
  idSrc <- S.get
  tt <- getTypeTable
  constants <- getList (getConstant tt)
  let knot0 = emptyKnot { knotTypeTable = tt
                        , knotValues = foldr (\c -> M.insert (constantId c) (toValue c)) M.empty constants
                        }
  -- We don't need the method refs here, we just need to populate the
  -- state with them
  (_, knot1) <- getListAccum getField knot0
  (_, knot2) <- getListAccum getMethodRef knot1
  (classes, knot3) <- getListAccum (getClass fknot) knot2
  let cache = foldr (\klass -> HM.insert (classType klass) klass) HM.empty classes
  return (DexFile { dexClasses = classes
                  , dexConstants = constants
                  , dexTypes = M.elems tt
                  , dexIdSrc = idSrc
                  , _dexClassesByType = cache
                  }, knot3)

getTypeTable :: S.Get (Map Int Type)
getTypeTable = do
  lst <- S.get
  return $ foldr (\(i, t) -> M.insert i t) M.empty lst

putTypeTable :: [Type] -> S.PutM (Map Type Int)
putTypeTable (zip [0..] -> ts) = do
  let m = foldr (\(i, t) -> M.insert t i) M.empty ts
  S.put ts
  return m

putConstant :: Map Type Int -> Constant -> S.Put
putConstant tt c =
  case c of
    ConstantInt uid i -> do
      S.putWord8 0
      S.put uid
      S.put i
    ConstantString uid s -> do
      S.putWord8 1
      S.put uid
      S.put s
    ConstantClass uid t -> do
      S.putWord8 2
      S.put uid
      putType tt t

getConstant :: Map Int Type -> S.Get Constant
getConstant tt = do
  tag <- S.getWord8
  case tag of
    0 -> ConstantInt <$> S.get <*> S.get
    1 -> ConstantString <$> S.get <*> S.get
    2 -> do
      uid <- S.get
      t <- getType tt
      return $ ConstantClass uid t
    _ -> error ("Deserializing invalid constant tag: " ++ show tag)

putType :: Map Type Int -> Type -> S.Put
putType tt t =
  case M.lookup t tt of
    Just tid -> S.put tid
    Nothing -> error ("Serializing type with no id: " ++ show t)

getType :: Map Int Type -> S.Get Type
getType tt = do
  tid <- S.get
  case M.lookup tid tt of
    Just t -> return t
    Nothing -> error ("Deserializing type with unknown id: " ++ show tid)

putClass :: Map Type Int -> Class -> S.Put
putClass tt klass = do
  S.put (classId klass)
  putType tt (classType klass)
  S.put (className klass)
  S.put (classSourceName klass)
  S.put (classAccessFlags klass)
  S.putMaybeOf (putType tt) (classParent klass)
  S.putMaybeOf S.put (fmap classId (classParentReference klass))
  S.putListOf (putType tt) (classInterfaces klass)
  putList (putMethod tt) (classDirectMethods klass)
  putList (putMethod tt) (classVirtualMethods klass)
  putList putAccessField (classStaticFields klass)
  putList putAccessField (classInstanceFields klass)

getClass :: Knot -> Knot -> S.Get (Class, Knot)
getClass fknot k0 = do
  let tt = knotTypeTable k0
  cid <- S.get
  ct <- getType tt
  name <- S.get
  sourceName <- S.get
  flags <- S.get
  parent <- S.getMaybeOf (getType tt)
  mparentRefId <- S.get
  let classErr = error ("Unknown class parent while decoding " ++ show cid)
      parentRef = fmap (\p -> fromMaybe classErr $ M.lookup p (knotClasses fknot)) mparentRefId
  ifaces <- S.getListOf (getType tt)
  (dms, k1) <- getListAccum (getMethod fknot) k0
  (vms, k2) <- getListAccum (getMethod fknot) k1
  sfields <- getList (getAccessField fknot)
  ifields <- getList (getAccessField fknot)
  let klass = Class { classId = cid
                    , classType = ct
                    , className = name
                    , classSourceName = sourceName
                    , classAccessFlags = flags
                    , classParent = parent
                    , classParentReference = parentRef
                    , classInterfaces = ifaces
                    , classDirectMethods = dms
                    , classVirtualMethods = vms
                    , classStaticFields = sfields
                    , classInstanceFields = ifields
                    , _classStaticFieldMap = indexFields sfields
                    , _classInstanceFieldMap = indexFields ifields
                    }
      k3 = k2 { knotClasses = M.insert cid klass (knotClasses k2) }
  return (klass, k3)
  where
    indexFields = foldr (\(_, f) -> HM.insert (fieldName f) f) HM.empty

putAccessField :: (AccessFlags, Field) -> S.Put
putAccessField (flags, f) = S.put flags >> S.put (fieldId f)

getAccessField :: Knot -> S.Get (AccessFlags, Field)
getAccessField fknot = do
  flags <- S.get
  fid <- S.get
  let errMsg = error ("No field for id " ++ show fid)
      f = fromMaybe errMsg $ M.lookup fid (knotFields fknot)
  return (flags, f)

putField :: Map Type Int -> Field -> S.Put
putField tt f = do
  S.put (fieldId f)
  S.put (fieldName f)
  putType tt (fieldType f)
  putType tt (fieldClass f)

getField :: Knot -> S.Get (Field, Knot)
getField k0 = do
  fid <- S.get
  name <- S.get
  ft <- getType tt
  fc <- getType tt
  let f = Field { fieldId = fid
                , fieldName = name
                , fieldType = ft
                , fieldClass = fc
                }
      k1 = k0 { knotFields = M.insert fid f (knotFields k0) }
  return (f, k1)
  where
    tt = knotTypeTable k0

putMethod :: Map Type Int -> Method -> S.Put
putMethod tt m = do
  S.put (methodId m)
  S.put (methodName m)
  putType tt (methodReturnType m)
  S.put (methodAccessFlags m)
  putList (putParameter tt) (methodParameters m)
  -- Encode the body as a list since that is a bit easier to decode.
  putList (putBlock tt) (fromMaybe [] (methodBody m))
  S.put (classId (methodClass m))

getMethod :: Knot -> Knot -> S.Get (Method, Knot)
getMethod fknot k0 = do
  mid <- S.get
  name <- S.get
  rt <- getType (knotTypeTable k0)
  flags <- S.get
  (ps, k1) <- getListAccum (getParameter fknot) k0
  (b, k2) <- getListAccum (getBlock fknot) k1
  cid <- S.get
  let errMsg = error ("No class " ++ show cid ++ " while decoding method " ++ show mid)
      klass = fromMaybe errMsg $ M.lookup cid (knotClasses fknot)
      m = Method { methodId = mid
                 , methodName = name
                 , methodReturnType = rt
                 , methodAccessFlags = flags
                 , methodParameters = ps
                 , methodBody = if null b then Nothing else Just b
                 , methodClass = klass
                 }
      k3 = k2 { knotMethods = M.insert mid m (knotMethods k2) }
  return (m, k3)

putParameter :: Map Type Int -> Parameter -> S.Put
putParameter tt p = do
  S.put (parameterId p)
  putType tt (parameterType p)
  S.put (parameterName p)
  S.put (parameterIndex p)
  S.put (methodId (parameterMethod p))

getParameter :: Knot -> Knot -> S.Get (Parameter, Knot)
getParameter fknot k = do
  pid <- S.get
  pt <- getType (knotTypeTable k)
  name <- S.get
  ix <- S.get
  mix <- S.get
  let errMsg = error ("No method " ++ show mix ++ " for parameter " ++ show pid)
      m = fromMaybe errMsg $ M.lookup mix (knotMethods fknot)
      p = Parameter { parameterId = pid
                    , parameterType = pt
                    , parameterName = name
                    , parameterIndex = ix
                    , parameterMethod = m
                    }
      k' = k { knotValues = M.insert pid (toValue p) (knotValues k) }
  return (p, k')

putBlock :: Map Type Int -> BasicBlock -> S.Put
putBlock tt b = do
  S.put (basicBlockId b)
  S.put (basicBlockNumber b)
  putList (putInstruction tt) (basicBlockInstructions b)
  S.put (basicBlockPhiCount b)
  S.put (map basicBlockId (basicBlockSuccessors b))
  S.put (map basicBlockId (basicBlockPredecessors b))
  S.put (methodId (basicBlockMethod b))

getBlock :: Knot -> Knot -> S.Get (BasicBlock, Knot)
getBlock fknot k0 = do
  bid <- S.get
  bnum <- S.get
  (is, k1) <- getListAccum (getInstruction fknot) k0
  phis <- S.get
  sids <- S.get
  pids <- S.get
  mid <- S.get
  let errMsg = error ("Could not find method " ++ show mid ++ " while decoding block " ++ show bid)
      m = fromMaybe errMsg $ M.lookup mid (knotMethods fknot)
      berrMsg i = error ("Could not translate block id " ++ show i ++ " while decoding block " ++ show bid)
      fromBlockId i = fromMaybe (berrMsg i) $ M.lookup i (knotBlocks fknot)
      b = BasicBlock { basicBlockId = bid
                     , basicBlockNumber = bnum
                     , _basicBlockInstructions = V.fromList is
                     , basicBlockPhiCount = phis
                     , basicBlockSuccessors = map fromBlockId sids
                     , basicBlockPredecessors = map fromBlockId pids
                     , basicBlockMethod = m
                     }
      k2 = k1 { knotBlocks = M.insert bid b (knotBlocks k1) }
  return (b, k2)

-- | Output the common values for each instruction, followed by a tag,
-- followed by instruction-specific data.
putInstruction :: Map Type Int -> Instruction -> S.Put
putInstruction tt i = do
  S.put (instructionId i)
  putType tt (instructionType i)
  S.put (basicBlockId (instructionBasicBlock i))
  case i of
    Return { returnValue = rv } -> do
      S.putWord8 0
      S.put (fmap valueId rv)
    MoveException {} -> do
      S.putWord8 1
    MonitorEnter { monitorReference = r } -> do
      S.putWord8 2
      S.put (valueId r)
    MonitorExit { monitorReference = r } -> do
      S.putWord8 3
      S.put (valueId r)
    CheckCast { castReference = r, castType = t } -> do
      S.putWord8 4
      S.put (valueId r)
      putType tt t
    InstanceOf { instanceOfReference = r
               , instanceOfType = t
               } -> do
      S.putWord8 5
      S.put (valueId r)
      putType tt t
    ArrayLength { arrayReference = r } -> do
      S.putWord8 6
      S.put (valueId r)
    NewInstance {} -> do
      S.putWord8 7
    NewArray { newArrayLength = len, newArrayContents = vs } -> do
      S.putWord8 8
      S.put (valueId len)
      S.put (fmap (map valueId) vs)
    FillArray { fillArrayReference = r, fillArrayContents = is } -> do
      S.putWord8 9
      S.put (valueId r)
      S.put is
    Throw { throwReference = r } -> do
      S.putWord8 10
      S.put (valueId r)
    ConditionalBranch { branchOperand1 = op1
                      , branchOperand2 = op2
                      , branchTestType = ty
                      , branchTarget = dest
                      , branchFallthrough = ft
                      } -> do
      S.putWord8 11
      S.put (valueId op1)
      S.put (valueId op2)
      S.put ty
      S.put (basicBlockId dest)
      S.put (basicBlockId ft)
    UnconditionalBranch { branchTarget = bt } -> do
      S.putWord8 12
      S.put (basicBlockId bt)
    Switch { switchValue = sv
           , switchTargets = ts
           , switchFallthrough = ft
           } -> do
      S.putWord8 13
      S.put (valueId sv)
      S.put (map (second basicBlockId) ts)
      S.put (basicBlockId ft)
    Compare { compareOperation = op
            , compareOperand1 = op1
            , compareOperand2 = op2
            } -> do
      S.putWord8 14
      S.put op
      S.put (valueId op1)
      S.put (valueId op2)
    UnaryOp { unaryOperand = v
            , unaryOperation = op
            } -> do
      S.putWord8 15
      S.put (valueId v)
      S.put op
    BinaryOp { binaryOperand1 = op1
             , binaryOperand2 = op2
             , binaryOperation = op
             } -> do
      S.putWord8 16
      S.put (valueId op1)
      S.put (valueId op2)
      S.put op
    ArrayGet { arrayReference = r, arrayIndex = ix } -> do
      S.putWord8 17
      S.put (valueId r)
      S.put (valueId ix)
    ArrayPut { arrayReference = r
             , arrayIndex = ix
             , arrayPutValue = v
             } -> do
      S.putWord8 18
      S.put (valueId r)
      S.put (valueId ix)
      S.put (valueId v)
    StaticGet { staticOpField = f } -> do
      S.putWord8 19
      S.put (fieldId f)
    StaticPut { staticOpField = f, staticOpPutValue = v } -> do
      S.putWord8 20
      S.put (fieldId f)
      S.put (valueId v)
    InstanceGet { instanceOpReference = r, instanceOpField = f } -> do
      S.putWord8 21
      S.put (valueId r)
      S.put (fieldId f)
    InstancePut { instanceOpReference = r
                , instanceOpField = f
                , instanceOpPutValue = v
                } -> do
      S.putWord8 22
      S.put (valueId r)
      S.put (fieldId f)
      S.put (valueId v)
    InvokeVirtual { invokeVirtualKind = k
                  , invokeVirtualMethod = mref
                  , invokeVirtualArguments = args
                  } -> do
      S.putWord8 23
      S.put k
      S.put (methodRefId mref)
      S.put $ F.toList $ fmap valueId args
    InvokeDirect { invokeDirectKind = k
                 , invokeDirectMethod = mref
                 , invokeDirectMethodDef = mdef
                 , invokeDirectArguments = args
                 } -> do
      S.putWord8 24
      S.put k
      S.put (methodRefId mref)
      S.put (fmap methodId mdef)
      S.put (fmap valueId args)
    Phi { phiValues = ivs } -> do
      S.putWord8 25
      S.put (map (\(b, v) -> (basicBlockId b, valueId v)) ivs)

getInstruction :: Knot -> Knot -> S.Get (Instruction, Knot)
getInstruction fknot k0 = do
  iid <- S.get
  it <- getType (knotTypeTable k0)
  let blockErr b = error ("No block with id " ++ show b ++ " while decoding instruction " ++ show iid)
      toBlock b = fromMaybe (blockErr b) $ M.lookup b (knotBlocks fknot)
      valueErr v = error ("No value with id " ++ show v ++ " while decoding instruction " ++ show iid)
      toVal v = fromMaybe (valueErr v) $ M.lookup v (knotValues fknot)
      mrefErr m = error ("No method ref with id " ++ show m ++ " while decoding instruction " ++ show iid)
      toMethodRef m = fromMaybe (mrefErr m) $ M.lookup m (knotMethodRefs fknot)
      getValue = toVal <$> S.get
      getBB = toBlock <$> S.get
      getMRef = toMethodRef <$> S.get
  bb <- getBB
  tag <- S.getWord8
  let fieldErr f = error ("No field with id " ++ show f ++ " while decoding instruction " ++ show iid ++ " tag " ++ show tag)
      toField f = fromMaybe (fieldErr f) $ M.lookup f (knotFields fknot)
      getF = toField <$> S.get
  case tag of
    0 -> do
      mrvid <- S.get
      let i = Return { instructionId = iid
                     , instructionType = it
                     , instructionBasicBlock = bb
                     , returnValue = fmap toVal mrvid
                     }
      return (i, addInstruction i k0)
    1 -> do
      let i = MoveException { instructionId = iid
                            , instructionType = it
                            , instructionBasicBlock = bb
                            }
      return (i, addInstruction i k0)
    2 -> do
      r <- getValue
      let i = MonitorEnter { instructionId = iid
                           , instructionType = it
                           , instructionBasicBlock = bb
                           , monitorReference = r
                           }
      return (i, addInstruction i k0)
    3 -> do
      r <- getValue
      let i = MonitorExit { instructionId = iid
                          , instructionType = it
                          , instructionBasicBlock = bb
                          , monitorReference = r
                          }
      return (i, addInstruction i k0)
    4 -> do
      r <- getValue
      t <- getType tt
      let i = CheckCast { instructionId = iid
                        , instructionType = it
                        , instructionBasicBlock = bb
                        , castReference = r
                        , castType = t
                        }
      return (i, addInstruction i k0)
    5 -> do
      r <- getValue
      t <- getType tt
      let i = InstanceOf { instructionId = iid
                         , instructionType = it
                         , instructionBasicBlock = bb
                         , instanceOfReference = r
                         , instanceOfType = t
                         }
      return (i, addInstruction i k0)
    6 -> do
      r <- getValue
      let i = ArrayLength { instructionId = iid
                          , instructionType = it
                          , instructionBasicBlock = bb
                          , arrayReference = r
                          }
      return (i, addInstruction i k0)
    7 -> do
      let i = NewInstance { instructionId = iid
                          , instructionType = it
                          , instructionBasicBlock = bb
                          }
      return (i, addInstruction i k0)
    8 -> do
      len <- getValue
      cids <- S.get
      let i = NewArray { instructionId = iid
                       , instructionType = it
                       , instructionBasicBlock = bb
                       , newArrayLength = len
                       , newArrayContents = fmap (map toVal) cids
                       }
      return (i, addInstruction i k0)
    9 -> do
      r <- getValue
      contents <- S.get
      let i = FillArray { instructionId = iid
                        , instructionType = it
                        , instructionBasicBlock = bb
                        , fillArrayReference = r
                        , fillArrayContents = contents
                        }
      return (i, addInstruction i k0)
    10 -> do
      r <- getValue
      let i = Throw { instructionId = iid
                    , instructionType = it
                    , instructionBasicBlock = bb
                    , throwReference = r
                    }
      return (i, addInstruction i k0)
    11 -> do
      op1 <- getValue
      op2 <- getValue
      test <- S.get
      dest <- getBB
      fallthrough <- getBB
      let i = ConditionalBranch { instructionId = iid
                                , instructionType = it
                                , instructionBasicBlock = bb
                                , branchOperand1 = op1
                                , branchOperand2 = op2
                                , branchTestType = test
                                , branchTarget = dest
                                , branchFallthrough = fallthrough
                                }
      return (i, addInstruction i k0)
    12 -> do
      t <- getBB
      let i = UnconditionalBranch { instructionId = iid
                                  , instructionType = it
                                  , instructionBasicBlock = bb
                                  , branchTarget = t
                                  }
      return (i, addInstruction i k0)
    13 -> do
      sv <- getValue
      rawTs <- S.get
      ft <- getBB
      let i = Switch { instructionId = iid
                     , instructionType = it
                     , instructionBasicBlock = bb
                     , switchValue = sv
                     , switchTargets = map (second toBlock) rawTs
                     , switchFallthrough = ft
                     }
      return (i, addInstruction i k0)
    14 -> do
      op <- S.get
      op1 <- getValue
      op2 <- getValue
      let i = Compare { instructionId = iid
                      , instructionType = it
                      , instructionBasicBlock = bb
                      , compareOperation = op
                      , compareOperand1 = op1
                      , compareOperand2 = op2
                      }
      return (i, addInstruction i k0)
    15 -> do
      v <- getValue
      op <- S.get
      let i = UnaryOp { instructionId = iid
                      , instructionType = it
                      , instructionBasicBlock = bb
                      , unaryOperand = v
                      , unaryOperation = op
                      }
      return (i, addInstruction i k0)
    16 -> do
      op1 <- getValue
      op2 <- getValue
      op <- S.get
      let i = BinaryOp { instructionId = iid
                       , instructionType = it
                       , instructionBasicBlock = bb
                       , binaryOperand1 = op1
                       , binaryOperand2 = op2
                       , binaryOperation = op
                       }
      return (i, addInstruction i k0)
    17 -> do
      r <- getValue
      ix <- getValue
      let i = ArrayGet { instructionId = iid
                       , instructionType = it
                       , instructionBasicBlock = bb
                       , arrayReference = r
                       , arrayIndex = ix
                       }
      return (i, addInstruction i k0)
    18 -> do
      r <- getValue
      ix <- getValue
      v <- getValue
      let i = ArrayPut { instructionId = iid
                       , instructionType = it
                       , instructionBasicBlock = bb
                       , arrayReference = r
                       , arrayIndex = ix
                       , arrayPutValue = v
                       }
      return (i, addInstruction i k0)
    19 -> do
      f <- getF
      let i = StaticGet { instructionId = iid
                        , instructionType = it
                        , instructionBasicBlock = bb
                        , staticOpField = f
                        }
      return (i, addInstruction i k0)
    20 -> do
      f <- getF
      v <- getValue
      let i = StaticPut { instructionId = iid
                        , instructionType = it
                        , instructionBasicBlock = bb
                        , staticOpField = f
                        , staticOpPutValue = v
                        }
      return (i, addInstruction i k0)
    21 -> do
      r <- getValue
      f <- getF
      let i = InstanceGet { instructionId = iid
                          , instructionType = it
                          , instructionBasicBlock = bb
                          , instanceOpReference = r
                          , instanceOpField = f
                          }
      return (i, addInstruction i k0)
    22 -> do
      r <- getValue
      f <- getF
      v <- getValue
      let i = InstancePut { instructionId = iid
                          , instructionType = it
                          , instructionBasicBlock = bb
                          , instanceOpReference = r
                          , instanceOpField = f
                          , instanceOpPutValue = v
                          }
      return (i, addInstruction i k0)
    23 -> do
      k <- S.get
      mref <- getMRef
      args <- map toVal <$> S.get
      case NEL.nonEmpty args of
        Nothing -> error ("Encountered an empty argument list for InvokeVirtual at instruction " ++ show iid)
        Just args' -> do
          let i = InvokeVirtual { instructionId = iid
                                , instructionType = it
                                , instructionBasicBlock = bb
                                , invokeVirtualKind = k
                                , invokeVirtualMethod = mref
                                , invokeVirtualArguments = args'
                                }
          return (i, addInstruction i k0)
    24 -> do
      let methodErr m = error ("No method for id " ++ show m ++ " while decoding instruction " ++ show iid)
          toM m = fromMaybe (methodErr m) $ M.lookup m (knotMethods fknot)
      k <- S.get
      mref <- getMRef
      m <- fmap toM <$> S.get
      args <- map toVal <$> S.get
      let i = InvokeDirect { instructionId = iid
                           , instructionType = it
                           , instructionBasicBlock = bb
                           , invokeDirectKind = k
                           , invokeDirectMethod = mref
                           , invokeDirectMethodDef = m
                           , invokeDirectArguments = args
                           }
      return (i, addInstruction i k0)
    25 -> do
      ivs <- map (\(b, v) -> (toBlock b, toVal v)) <$> S.get
      let i = Phi { instructionId = iid
                  , instructionType = it
                  , instructionBasicBlock = bb
                  , phiValues = ivs
                  }
      return (i, addInstruction i k0)
    _ -> error ("Unexpected instruction tag " ++ show tag)
  where
    tt = knotTypeTable k0

addInstruction :: Instruction -> Knot -> Knot
addInstruction i k = k { knotValues = M.insert (instructionId i) (toValue i) (knotValues k) }

putMethodRef :: Map Type Int -> MethodRef -> S.Put
putMethodRef tt mref = do
  S.put (methodRefId mref)
  putType tt (methodRefClass mref)
  putType tt (methodRefReturnType mref)
  putList (putType tt) (methodRefParameterTypes mref)
  S.put (methodRefName mref)

getMethodRef :: Knot -> S.Get (MethodRef, Knot)
getMethodRef k0 = do
  rid <- S.get
  let tt = knotTypeTable k0
  ct <- getType tt
  rt <- getType tt
  pts <- getList (getType tt)
  name <- S.get
  let mref = MethodRef { methodRefId = rid
                       , methodRefClass = ct
                       , methodRefReturnType = rt
                       , methodRefParameterTypes = pts
                       , methodRefName = name
                       }
      k1 = k0 { knotMethodRefs = M.insert rid mref (knotMethodRefs k0) }
  return (mref, k1)

putList :: (a -> S.PutM ()) -> [a] -> S.Put
putList p l = do
  S.putWord64le (fromIntegral (length l))
  mapM_ p l

getList :: S.Get a -> S.Get [a]
getList p = S.getWord64le >>= go []
  where
    go lst 0 = return (reverse lst)
    go lst !n = do
      elt <- p
      go (elt : lst) (n - 1)

getListAccum :: (k -> S.Get (a, k)) -> k -> S.Get ([a], k)
getListAccum p knot0 = S.getWord64le >>= go ([], knot0)
  where
    go (lst, !k) 0 = return (reverse lst, k)
    go (lst, !k) !n = do
      (elt, k') <- p k
      go (elt : lst, k') (n - 1)

dexMethodRefs :: DexFile -> [MethodRef]
dexMethodRefs df = Set.toList $ Set.fromList $
                   [ mref
                   | k <- dexClasses df
                   , m <- classDirectMethods k ++ classVirtualMethods k
                   , body <- maybeToList (methodBody m)
                   , block <- body
                   , i <- basicBlockInstructions block
                   , mref <- maybeMethodRef i
                   ]
  where
    maybeMethodRef i =
      case i of
        InvokeVirtual { invokeVirtualMethod = mref } -> [mref]
        InvokeDirect { invokeDirectMethod = mref } -> [mref]
        _ -> []

dexFields :: DexFile -> [Field]
dexFields df = Set.toList $ Set.fromList (ifields ++ cfields)
  where
    cfields = [ f
              | klass <- dexClasses df
              , (_, f) <- classStaticFields klass ++ classInstanceFields klass
              ]
    ifields = [ f
              | k <- dexClasses df
              , m <- classDirectMethods k ++ classVirtualMethods k
              , body <- maybeToList (methodBody m)
              , block <- body
              , i <- basicBlockInstructions block
              , f <- referencedField i
              ]
    referencedField i =
      case i of
        StaticGet { staticOpField = f } -> [f]
        StaticPut { staticOpField = f } -> [f]
        InstanceGet { instanceOpField = f } -> [f]
        InstancePut { instanceOpField = f } -> [f]
        _ -> []
