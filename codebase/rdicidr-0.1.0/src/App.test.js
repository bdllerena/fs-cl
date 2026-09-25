import { render, screen } from "@testing-library/react";
import App from "./App";

// App renders process.env.REACT_APP_API_URL, which CRA inlines at build time. It is
// not set in CI, in the Dockerfile, or in any committed .env file, so the test owns
// its fixture instead of asserting on deployment configuration.
process.env.REACT_APP_API_URL = "https://api.rdicidr.com";

test("renders the CIDR calculator header", () => {
  render(<App />);
  expect(screen.getByText(/CIDR Calculator/i)).toBeInTheDocument();
});

test("displays the configured API URL", () => {
  render(<App />);
  expect(screen.getByText(/api\.rdicidr\.com/i)).toBeInTheDocument();
});
