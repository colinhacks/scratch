export function greet(name: string, timeOfDay?: "morning" | "afternoon" | "evening"): string {
  const timeGreeting = timeOfDay 
    ? `Good ${timeOfDay}, `
    : "Hello, ";
  return `${timeGreeting}${name}!`;
}

export function greetMultiple(names: string[]): string {
  if (names.length === 0) return "Hello, everyone!";
  if (names.length === 1) return greet(names[0]);
  const last = names[names.length - 1];
  const others = names.slice(0, -1).join(", ");
  return greet(`${others} and ${last}`);
}