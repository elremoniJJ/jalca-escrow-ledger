export const idlFactory = ({ IDL }) => {
  const GameOutcome = IDL.Variant({
    'draw' : IDL.Null,
    'black' : IDL.Null,
    'white' : IDL.Null,
  });
  const BetRecord = IDL.Record({
    'username' : IDL.Text,
    'player' : IDL.Principal,
    'wallet_address' : IDL.Text,
    'pot_tier' : IDL.Nat,
    'anonymous' : IDL.Bool,
    'amount_e8s' : IDL.Nat,
    'outcome' : GameOutcome,
  });
  const TierSummary = IDL.Record({
    'winning_bets' : IDL.Nat,
    'total_pot_e8s' : IDL.Nat,
    'total_bets' : IDL.Nat,
    'pot_tier' : IDL.Nat,
  });
  const GameHistoryRecord = IDL.Record({
    'result' : GameOutcome,
    'bets' : IDL.Vec(BetRecord),
    'end_time' : IDL.Nat,
    'game_id' : IDL.Text,
    'tier_summaries' : IDL.Vec(TierSummary),
  });
  const PlaceBetArgs = IDL.Record({
    'username' : IDL.Text,
    'player' : IDL.Principal,
    'wallet_address' : IDL.Text,
    'pot_tier' : IDL.Nat,
    'anonymous' : IDL.Bool,
    'amount_e8s' : IDL.Nat,
    'outcome' : GameOutcome,
  });
  const EscrowError = IDL.Variant({
    'InsufficientAllowance' : IDL.Null,
    'NoApproval' : IDL.Null,
    'Unauthorized' : IDL.Null,
    'InvalidTier' : IDL.Null,
    'NoActiveGame' : IDL.Null,
    'TransferFailed' : IDL.Text,
  });
  const Result_1 = IDL.Variant({ 'ok' : IDL.Nat, 'err' : EscrowError });
  const ReportOutcomeArgs = IDL.Record({
    'result' : GameOutcome,
    'end_time' : IDL.Nat,
    'game_id' : IDL.Text,
  });
  const Result = IDL.Variant({ 'ok' : IDL.Null, 'err' : EscrowError });
  const StartGameArgs = IDL.Record({
    'start_time' : IDL.Nat,
    'game_id' : IDL.Text,
  });
  const EscrowCanister = IDL.Service({
    'getAllowlist' : IDL.Func([], [IDL.Principal], ['query']),
    'getGameHistory' : IDL.Func([], [IDL.Vec(GameHistoryRecord)], ['query']),
    'getLockedGamePots' : IDL.Func(
        [],
        [IDL.Opt(IDL.Tuple(IDL.Text, IDL.Vec(BetRecord)))],
        ['query'],
      ),
    'getNextGamePots' : IDL.Func([], [IDL.Vec(BetRecord)], ['query']),
    'place_bet' : IDL.Func([PlaceBetArgs], [Result_1], []),
    'report_outcome' : IDL.Func([ReportOutcomeArgs], [Result], []),
    'start_game' : IDL.Func([StartGameArgs], [Result], []),
    'testLedgerConnection' : IDL.Func([], [IDL.Text], []),
  });
  return EscrowCanister;
};
export const init = ({ IDL }) => { return []; };
