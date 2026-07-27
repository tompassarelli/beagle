export {};
declare function host_parse(_arg0: string): number;

function parse_or_zero(s: string): number {
  return host_parse(s);
}

console.log(parse_or_zero("17"));
