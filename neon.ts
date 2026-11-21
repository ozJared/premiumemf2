import { defineConfig } from "@neon/config/v1";

export default defineConfig({
  auth: false,
  buckets: {
    "premium-emf-media": { access: "public_read" },
  },
  // Branch policy: per-branch tuning
  branch: (branch) => {
    if (branch.isDefault) {
      // Default branch: no overrides, uses project defaults
      return {};
    }
    // Website deployment branches persist until explicitly deleted.
    return {};
  },
});
