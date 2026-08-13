import { Thing } from "./other.js";

/**
 * A doc comment that mentions class Decoy { and a brace.
 */
export class Box<
    T extends { weight: number } = { weight: number },
> extends Thing<T> {
    readonly isBox: boolean;
    width: number;
    label: string;
    constructor(width?: number, height?: number);
    scale(factor: number): this;
    scale(x: number, y: number, z: number): this;
    add(...children: Box[]): this;
    set(...args: [color: Box] | [r: number, g: number, b: number]): this;
    describe(): string;
    private hidden(): void;
    static of(width: number): Box;
    nested: { a: number };
    maybe: number | null;
    callback: (x: number) => void;
}

export interface NotAClass {
    width: number;
}
