import type { Principal } from '@dfinity/principal';
import type { ActorMethod } from '@dfinity/agent';
import type { IDL } from '@dfinity/candid';

export interface BetRecord {
  'username' : string,
  'player' : Principal,
  'wallet_address' : string,
  'pot_tier' : bigint,
  'anonymous' : boolean,
  'amount_e8s' : bigint,
  'outcome' : GameOutcome,
}
export interface EscrowCanister {
  'getAllowlist' : ActorMethod<[], Principal>,
  'getGameHistory' : ActorMethod<[], Array<GameHistoryRecord>>,
  'getLockedGamePots' : ActorMethod<[], [] | [[string, Array<BetRecord>]]>,
  'getNextGamePots' : ActorMethod<[], Array<BetRecord>>,
  'place_bet' : ActorMethod<[PlaceBetArgs], Result_1>,
  'report_outcome' : ActorMethod<[ReportOutcomeArgs], Result>,
  'start_game' : ActorMethod<[StartGameArgs], Result>,
  'testLedgerConnection' : ActorMethod<[], string>,
}
export type EscrowError = { 'InsufficientAllowance' : null } |
  { 'NoApproval' : null } |
  { 'Unauthorized' : null } |
  { 'InvalidTier' : null } |
  { 'NoActiveGame' : null } |
  { 'TransferFailed' : string };
export interface GameHistoryRecord {
  'result' : GameOutcome,
  'bets' : Array<BetRecord>,
  'end_time' : bigint,
  'game_id' : string,
  'tier_summaries' : Array<TierSummary>,
}
export type GameOutcome = { 'draw' : null } |
  { 'black' : null } |
  { 'white' : null };
export interface PlaceBetArgs {
  'username' : string,
  'player' : Principal,
  'wallet_address' : string,
  'pot_tier' : bigint,
  'anonymous' : boolean,
  'amount_e8s' : bigint,
  'outcome' : GameOutcome,
}
export interface ReportOutcomeArgs {
  'result' : GameOutcome,
  'end_time' : bigint,
  'game_id' : string,
}
export type Result = { 'ok' : null } |
  { 'err' : EscrowError };
export type Result_1 = { 'ok' : bigint } |
  { 'err' : EscrowError };
export interface StartGameArgs { 'start_time' : bigint, 'game_id' : string }
export interface TierSummary {
  'winning_bets' : bigint,
  'total_pot_e8s' : bigint,
  'total_bets' : bigint,
  'pot_tier' : bigint,
}
export interface _SERVICE extends EscrowCanister {}
export declare const idlFactory: IDL.InterfaceFactory;
export declare const init: (args: { IDL: typeof IDL }) => IDL.Type[];
