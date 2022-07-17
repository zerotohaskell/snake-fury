{-# LANGUAGE MultiWayIf #-}
{-|
This module defines the logic of the game and the communication with the `Board.RenderState`
-}
module GameState where

import RenderState (BoardInfo (..), Point, DeltaBoard)
import qualified RenderState as Board
import Data.Sequence ( Seq(..))
import qualified Data.Sequence as S
import System.Random ( uniformR, RandomGen(split), StdGen, Random (randomR), mkStdGen )
import Data.Maybe (isJust)
import Control.Monad.Trans.Reader (ReaderT (runReaderT), ask, runReader)
import Control.Monad.Trans.State.Strict (State, get, put, modify, gets, runState)
import Control.Monad.Trans.Class ( MonadTrans(lift) )

data Movement = North | South | East | West deriving (Show, Eq)
data SnakeSeq = SnakeSeq {snakeHead :: Point, snakeBody :: Seq Point} deriving (Show, Eq)
data GameState = GameState
  { snakeSeq :: SnakeSeq
  , applePosition :: Point
  , movement :: Movement
  --, boardInfo :: BoardInfo
  , randomGen :: StdGen
  }
  deriving (Show, Eq)

type GameStep a = ReaderT BoardInfo (State GameState) a

-- | calculate the oposite movement. This is done because if snake is moving up
-- We can not change direction to south.
opositeMovement :: Movement -> Movement
opositeMovement North = South
opositeMovement South = North
opositeMovement East = West
opositeMovement West = East

-- | Purely creates a random point within the board limits
makeRandomPoint :: GameStep Point
makeRandomPoint = do
  BoardInfo n i <- ask
  g <- lift $ gets randomGen
  let (g1, g2)  = split g
      (n', g1') = uniformR (1, n) g1
      (i', _) = uniformR (1, i) g2
      newPoint  = (n', i')
  lift $ modify $ \x -> x{randomGen = g1'}
  pure newPoint

-- | Check if a point is in the snake
inSnake :: Point -> SnakeSeq  -> Bool
inSnake x0 (SnakeSeq x1 seq) = x0 == x1 || isJust (x0 `S.elemIndexL` seq)

-- | Calculates de new head of the snake
nextHead :: BoardInfo -> GameState -> Point
nextHead (BoardInfo h w) (GameState (SnakeSeq (x, y) _) _ mov _) =
  case mov of
    North -> if x - 1 <= 0 then (h, y) else (x - 1, y)
    South -> if x + 1  > h then (1, y) else (x + 1, y)
    East  -> if y + 1  > w then (x, 1) else (x, y + 1)
    West  -> if y - 1 <= 0 then (x, w) else (x, y - 1)

-- | Calculates a new random apple, avoiding creating the apple in the same place, or in the snake body
newApple :: GameStep Point
newApple = do 
  bi <- ask
  GameState snake_body old_apple move sg <- lift get
  new_apple <- makeRandomPoint
  if new_apple == old_apple || new_apple `inSnake` snake_body
     then newApple
     else lift (modify $ \x -> x{applePosition = new_apple} )>> pure new_apple

-- | move the snake's head forward without removing the tail. (This is the case of eating an apple)
extendSnake ::  Point -> GameStep DeltaBoard
extendSnake new_head = do 
  binfo <- ask
  SnakeSeq old_head snake_body <- lift $ gets snakeSeq
  let new_snake = SnakeSeq new_head (old_head :<| snake_body)
      delta     = [(new_head, Board.SnakeHead), (old_head, Board.Snake)]
  lift $ modify $ \gstate -> gstate{snakeSeq = new_snake}
  pure delta

-- | displace snake, that is: remove the tail and move the head forward (This is the case of eating an apple)
displaceSnake :: Point -> GameStep DeltaBoard
displaceSnake new_head = do
  binfo <- ask
  SnakeSeq old_head snake_body <- lift $ gets snakeSeq
  case snake_body of
    S.Empty -> let new_snake = SnakeSeq new_head S.empty
                   delta = [(new_head, Board.SnakeHead), (old_head, Board.Empty)]
                in lift (modify $ \x -> x{snakeSeq = new_snake}) >> pure delta
    xs :|> t -> let new_snake = SnakeSeq new_head (old_head :<| xs)
                    delta = [(new_head, Board.SnakeHead), (old_head, Board.Snake), (t, Board.Empty)]
                 in lift (modify $ \x -> x{snakeSeq = new_snake}) >> pure delta

-- | Moves the snake based on the current direction.
step :: GameStep [Board.RenderMessage]
step = do
  bi <- ask
  gstate@(GameState s applePos _ _) <- lift get
  let  newHead           = nextHead bi gstate
       isEatingApple     = newHead == applePos
       isColision        = newHead `inSnake` s

  if | isColision -> pure [Board.GameOver]
     | isEatingApple -> do delta <- extendSnake newHead
                           newApplePos <- newApple
                           let delta' = (newApplePos, Board.Apple):delta
                           pure [Board.RenderBoard delta', Board.Score]
     | otherwise -> do delta <- displaceSnake newHead
                       pure [Board.RenderBoard delta]

move :: BoardInfo -> GameState -> ([Board.RenderMessage], GameState)
move =  runState . runReaderT step