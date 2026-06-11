export class ApiError extends Error {
    status: number;
    details?: string;
    data?: Record<string, unknown>;
    constructor(status: number, message: string, options?: {
        details?: string;
        data?: Record<string, unknown>;
    }) {
        super(message);
        this.status = status;
        this.details = options?.details;
        this.data = options?.data;
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
export class ServiceUnavailableError extends ApiError {
    constructor(message = "Service temporarily unavailable") {
        super(503, message);
    }
}
export class IntegrationError extends ApiError {
    constructor(message: string, options?: {
        details?: string;
        data?: Record<string, unknown>;
    }) {
        super(502, message, options);
    }
}
