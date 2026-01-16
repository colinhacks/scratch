export type GreetingStyle = "formal" | "casual" | "enthusiastic";

const greetings: Record<GreetingStyle, (name: string) => string> = {
  formal: (name) => `Good day, ${name}. It is a pleasure to meet you.`,
  casual: (name) => `Hey ${name}, what's up?`,
  enthusiastic: (name) => `${name}! So great to see you!`,
};

export function greet(name: string, style: GreetingStyle = "casual"): string {
  return greetings[style](name);
}

export function greetAll(names: string[], style: GreetingStyle = "casual"): string[] {
  return names.map((name) => greet(name, style));
}
