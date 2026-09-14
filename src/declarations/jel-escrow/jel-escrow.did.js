export const idlFactory = ({ IDL }) => {
  const GameOutcome = IDL.Variant({
    'draw' : IDL.Null,
    'black' : IDL.Null,
    'white' : IDL.Null,
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
    'place_bet' : IDL.Func([PlaceBetArgs], [Result_1], []),
    'report_outcome' : IDL.Func([ReportOutcomeArgs], [Result], []),
    'start_game' : IDL.Func([StartGameArgs], [Result], []),
    'testLedgerConnection' : IDL.Func([], [IDL.Text], []),
  });
  return EscrowCanister;
};
export const init = ({ IDL }) => { return []; };
