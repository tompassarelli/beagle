export default class Ghost {
    opacity: number;
    constructor(opacity?: number);
    fade(amount: number): void;
    static conjure(): Ghost;
}
