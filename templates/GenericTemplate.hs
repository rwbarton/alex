-- -----------------------------------------------------------------------------
-- ALEX TEMPLATE
--
-- This code is in the PUBLIC DOMAIN; you may copy it freely and use
-- it for any purpose whatsoever.

-- -----------------------------------------------------------------------------
-- INTERNALS and main scanner engine

#ifdef ALEX_GHC
#define ILIT(n) n#
#define IBOX(n) (I# (n))
#define FAST_INT Int#
#define LT(n,m) (n <# m)
#define GTE(n,m) (n >=# m)
#define EQ(n,m) (n ==# m)
#define PLUS(n,m) (n +# m)
#define MINUS(n,m) (n -# m)
#define TIMES(n,m) (n *# m)
#define NEGATE(n) (negateInt# (n))
#define IF_GHC(x) (x)
#else
#define ILIT(n) (n)
#define IBOX(n) (n)
#define FAST_INT Int
#define LT(n,m) (n < m)
#define GTE(n,m) (n >= m)
#define EQ(n,m) (n == m)
#define PLUS(n,m) (n + m)
#define MINUS(n,m) (n - m)
#define TIMES(n,m) (n * m)
#define NEGATE(n) (negate (n))
#define IF_GHC(x)
#endif

#ifdef ALEX_GHC
#undef __GLASGOW_HASKELL__
#define ALEX_IF_GHC_GT_500 #if __GLASGOW_HASKELL__ > 500
#define ALEX_IF_GHC_GE_503 #if __GLASGOW_HASKELL__ >= 503
#define ALEX_ELIF_GHC_500 #elif __GLASGOW_HASKELL__ == 500
#define ALEX_ELSE #else
#define ALEX_ENDIF #endif
#endif

#ifdef ALEX_GHC
data AlexAddr = AlexA# Addr#

{-# INLINE alexIndexShortOffAddr #-}
alexIndexShortOffAddr (AlexA# arr) off =
ALEX_IF_GHC_GT_500
	narrow16Int# i
ALEX_ELIF_GHC_500
	intToInt16# i
ALEX_ELSE
	(i `iShiftL#` 16#) `iShiftRA#` 16#
ALEX_ENDIF
  where
ALEX_IF_GHC_GE_503
	i = word2Int# ((high `uncheckedShiftL#` 8#) `or#` low)
ALEX_ELSE
	i = word2Int# ((high `shiftL#` 8#) `or#` low)
ALEX_ENDIF
	high = int2Word# (ord# (indexCharOffAddr# arr (off' +# 1#)))
	low  = int2Word# (ord# (indexCharOffAddr# arr off'))
	off' = off *# 2#
#else
alexIndexShortOffAddr arr off = arr ! off
#endif

-- -----------------------------------------------------------------------------
-- Main lexing routines

data AlexReturn a
  = AlexEOF
  | AlexError  !AlexInput
  | AlexSkip   !AlexInput !Int
  | AlexToken  !AlexInput !Int a

-- alexScan :: AlexInput -> StartCode -> Maybe (AlexInput,Int,act)
alexScan input IBOX(sc)
  = alexScanUser undefined input IBOX(sc)

alexScanUser user input IBOX(sc)
  = case alex_scan_tkn user input ILIT(0) input sc AlexNone of
	(AlexNone, input') ->
		case alexGetChar input of
			Nothing -> 
#ifdef ALEX_DEBUG
				   trace ("End of input.") $
#endif
				   AlexEOF
			Just _ ->
#ifdef ALEX_DEBUG
				   trace ("Error.") $
#endif
				   AlexError input

	(AlexLastSkip input len, _) ->
#ifdef ALEX_DEBUG
		trace ("Skipping.") $ 
#endif
		AlexSkip input len

	(AlexLastAcc k input len, _) ->
#ifdef ALEX_DEBUG
		trace ("Accept.") $ 
#endif
		AlexToken input len k


-- Push the input through the DFA, remembering the most recent accepting
-- state it encountered.

alex_scan_tkn user orig_input len input s last_acc =
  input `seq` -- strict in the input
  case s of 
    ILIT(-1) -> (last_acc, input)
    _ -> alex_scan_tkn' user orig_input len input s last_acc

alex_scan_tkn' user orig_input len input s last_acc =
  let 
	new_acc = check_accs (alex_accept `unsafeAt` IBOX(s))
  in
  new_acc `seq`
  case alexGetChar input of
     Nothing -> (new_acc, input)
     Just (c, new_input) -> 
#ifdef ALEX_DEBUG
        trace ("State: " ++ show IBOX(s) ++ ", char: " ++ show c) $
#endif
	let
		base   = alexIndexShortOffAddr alex_base s
		IBOX(ord_c) = ord c
		offset = PLUS(base,ord_c)
		check  = alexIndexShortOffAddr alex_check offset
		
		new_s = if GTE(offset,ILIT(0)) && EQ(check,ord_c)
			  then alexIndexShortOffAddr alex_table offset
			  else alexIndexShortOffAddr alex_deflt s
	in
	alex_scan_tkn user orig_input PLUS(len,ILIT(1)) new_input new_s new_acc

  where
	check_accs [] = last_acc
	check_accs (AlexAcc a : _) = AlexLastAcc a input IBOX(len)
	check_accs (AlexAccSkip : _)  = AlexLastSkip  input IBOX(len)
	check_accs (AlexAccPred a pred : rest)
	   | pred user orig_input IBOX(len) input
	   = AlexLastAcc a input IBOX(len)
	check_accs (AlexAccSkipPred pred : rest)
	   | pred user orig_input IBOX(len) input
	   = AlexLastSkip input IBOX(len)
	check_accs (_ : rest) = check_accs rest

data AlexLastAcc a
  = AlexNone
  | AlexLastAcc a !AlexInput !Int
  | AlexLastSkip  !AlexInput !Int

data AlexAcc a user
  = AlexAcc a
  | AlexAccSkip
  | AlexAccPred a (AlexAccPred user)
  | AlexAccSkipPred (AlexAccPred user)

type AlexAccPred user = user -> AlexInput -> Int -> AlexInput -> Bool

-- -----------------------------------------------------------------------------
-- Predicates on a rule

alexAndPred p1 p2 user in1 len in2
  = p1 user in1 len in2 && p2 user in1 len in2

--alexPrevCharIsPred :: Char -> AlexAccPred _ 
alexPrevCharIs c _ input _ _ = c == alexInputPrevChar input

--alexPrevCharIsOneOfPred :: Array Char Bool -> AlexAccPred _ 
alexPrevCharIsOneOf arr _ input _ _ = arr ! alexInputPrevChar input

--alexRightContext :: Int -> AlexAccPred _
alexRightContext IBOX(sc) user _ _ input = 
     case alex_scan_tkn user input ILIT(0) input sc AlexNone of
	  (AlexNone, _) -> False
	  _ -> True
	-- TODO: there's no need to find the longest
	-- match when checking the right context, just
	-- the first match will do.

-- used by wrappers
iUnbox IBOX(i) = i