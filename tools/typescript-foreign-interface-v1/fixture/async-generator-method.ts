export class AsyncGeneratorOwner {
  private closed = false;

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
