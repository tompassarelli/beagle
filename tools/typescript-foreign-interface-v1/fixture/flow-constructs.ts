interface AllocationEstimate {
  effectiveWeight: number;
  approximateShare: number;
}

export async function awaitValue(load: () => Promise<string>): Promise<string> {
  return await load();
}

export function collectWeights(keys: readonly string[]): Partial<Record<string, number>> {
  const result: Partial<Record<string, number>> = {};
  for (const key of keys) {
    if (key.length > 0) result[key] = 1;
  }
  return result;
}

export function assignShares(
  estimates: AllocationEstimate[],
  total: number,
): AllocationEstimate[] {
  for (const estimate of estimates)
    estimate.approximateShare = total > 0 ? estimate.effectiveWeight / total : 0;
  return estimates;
}
