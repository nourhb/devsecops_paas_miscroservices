export class ApiError extends Error {
  status: number;

  constructor(status: number, message: string) {
    super(message);
    this.status = status;
  }
}

export class UnauthorizedError extends ApiError {
  constructor(message = "Unauthorized") {
    super(401, message);
  }
}

export class ForbiddenError extends ApiError {
  constructor(message = "Forbidden") {
    super(403, message);
  }
}

export class NotFoundError extends ApiError {
  constructor(message = "Not found") {
    super(404, message);
  }
}

export class ValidationError extends ApiError {
  constructor(message = "Bad request") {
    super(400, message);
  }
}

export class SecurityGateError extends ApiError {
  constructor(message = "Security gate failed") {
    super(422, message);
  }
}

/** Upstream Jenkins, Kubernetes, registry, etc. */
export class IntegrationError extends ApiError {
  constructor(message: string) {
    super(502, message);
  }
}
