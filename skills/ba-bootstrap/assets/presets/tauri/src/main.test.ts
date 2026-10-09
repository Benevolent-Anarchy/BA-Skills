import { expect, test } from "vitest";

test("the starter renders the project title", async () => {
  document.body.innerHTML = '<div id="app"></div>';
  await import("./main");
  const title = document.querySelector("#app h1");
  expect(title).not.toBeNull();
  expect(title?.textContent).toBe(document.title);
});
