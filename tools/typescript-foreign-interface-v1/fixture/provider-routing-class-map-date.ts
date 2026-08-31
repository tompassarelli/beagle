export type FocusedProviderSelectionFailure =
  | "provider_unavailable"
  | "blocked_preflight";

export class FocusedProviderSelectionError extends Error {
  readonly preSideEffect = true;
  readonly processOutcome: "blocked_preflight" | undefined;

  constructor(readonly kind: FocusedProviderSelectionFailure, message: string) {
    super(message);
    this.name = "FocusedProviderSelectionError";
    this.processOutcome = kind === "blocked_preflight" ? "blocked_preflight" : undefined;
  }
}

export const focusedProviderMap = new Map<string, number>([["openai", 1]]);
export const focusedObservedAt = new Date();
