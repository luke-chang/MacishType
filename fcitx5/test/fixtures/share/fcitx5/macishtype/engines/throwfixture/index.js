function inner() {
  throw new Error("boom from engine");
}
inner();
export default class {};
