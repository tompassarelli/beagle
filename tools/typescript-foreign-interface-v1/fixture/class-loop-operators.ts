export class MutableBucket {
  private selected?: string;
  private visits = 0;

  constructor(readonly label: string, initial?: string) {
    this.selected = initial;
  }

  choose(candidate: string): void {
    this.selected ??= candidate;
    this.visits += 1;
    void Promise.resolve(candidate);
  }

  owns(key: string, values: Record<string, string>): boolean {
    return key in values;
  }

  count(values: readonly string[]): number {
    let count = 0;
    for (const value of values) {
      if (!value) continue;
      count += 1;
    }
    for (let index = 0; index < 2; index++) count += index;
    while (count > 8) count -= 1;
    return count;
  }
}

export function makeBucket(label: string): MutableBucket {
  return new MutableBucket(label);
}

export function normalizeError(value: unknown): Error {
  return value instanceof Error ? value : new Error("not an error");
}

export function emptyNames(): Set<string> {
  return new Set<string>();
}
