export class AsyncGeneratorOwner {
  private closed = false;

  async *attempt(values: AsyncIterable<string>): AsyncGenerator<string> {
    let launched = false;
    try {
      launched = true;
    } catch (error) {
      throw error;
    }
    if (!launched) throw new Error("launch preflight did not settle");
    for await (const value of values) {
      yield value;
    }
    return;
  }

  async *session(values: AsyncIterable<string>): AsyncGenerator<string> {
    try {
      for await (const value of values) {
        yield value;
      }
      return;
    } finally {
      this.closed = true;
    }
  }

  isClosed(): boolean {
    return this.closed;
  }
}
