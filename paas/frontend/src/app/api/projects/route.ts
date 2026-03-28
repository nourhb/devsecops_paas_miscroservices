/**
 * REST-style plural alias for `/api/project`.
 * Same auth, validation, and Jenkins createPipeline hook as the singular route.
 */
export { GET, POST, runtime } from "../project/route";
