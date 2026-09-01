import * as compiler from "./selfhost/main.js";

compiler["-main"](...Bun.argv.slice(2));
