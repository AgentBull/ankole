/** Exception type used for errors related to schema definition. */
export class SchemaError extends Error {}

/**
 * Exception type used when validating content against a schema, when
 * checking JSON input, or when validating change sets.
 */
export class ValidationError extends Error {}
