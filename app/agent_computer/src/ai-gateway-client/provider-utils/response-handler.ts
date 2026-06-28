import { APICallError, EmptyResponseBodyError } from '@/ai-gateway-client/provider'
import { extractResponseHeaders } from './extract-response-headers'
import { parseJSON, safeParseJSON, type ParseResult } from './parse-json'
import { parseJsonEventStream } from './parse-json-event-stream'
import { readResponseWithSizeLimit } from './read-response-with-size-limit'
import type { FlexibleSchema } from './schema'

export type ResponseHandler<RETURN_TYPE> = (options: {
  url: string
  requestBodyValues: unknown
  response: Response
  abortSignal?: AbortSignal
}) => PromiseLike<{
  value: RETURN_TYPE
  rawValue?: unknown
  responseHeaders?: Record<string, string>
}>

const textDecoder = new TextDecoder()

async function readResponseBodyAsText({ response, url }: { response: Response; url: string }) {
  return textDecoder.decode(
    await readResponseWithSizeLimit({
      response,
      url
    })
  )
}

export const createJsonErrorResponseHandler =
  <T>({
    errorSchema,
    errorToMessage,
    isRetryable
  }: {
    errorSchema: FlexibleSchema<T>
    errorToMessage: (error: T) => string
    isRetryable?: (response: Response, error?: T) => boolean
  }): ResponseHandler<APICallError> =>
  async ({ response, url, requestBodyValues }) => {
    const responseBody = await readResponseBodyAsText({ response, url })
    const responseHeaders = extractResponseHeaders(response)

    // Some providers return an empty response body for some errors:
    if (responseBody.trim() === '') {
      return {
        responseHeaders,
        value: new APICallError({
          message: response.statusText,
          url,
          requestBodyValues,
          statusCode: response.status,
          responseHeaders,
          responseBody,
          isRetryable: isRetryable?.(response)
        })
      }
    }

    // resilient parsing in case the response is not JSON or does not match the schema:
    try {
      const parsedError = await parseJSON({
        text: responseBody,
        schema: errorSchema
      })

      return {
        responseHeaders,
        value: new APICallError({
          message: errorToMessage(parsedError),
          url,
          requestBodyValues,
          statusCode: response.status,
          responseHeaders,
          responseBody,
          data: parsedError,
          isRetryable: isRetryable?.(response, parsedError)
        })
      }
    } catch {
      return {
        responseHeaders,
        value: new APICallError({
          message: response.statusText,
          url,
          requestBodyValues,
          statusCode: response.status,
          responseHeaders,
          responseBody,
          isRetryable: isRetryable?.(response)
        })
      }
    }
  }

export const createEventSourceResponseHandler =
  <T>(chunkSchema: FlexibleSchema<T>): ResponseHandler<ReadableStream<ParseResult<T>>> =>
  async ({ response, abortSignal }: { response: Response; abortSignal?: AbortSignal }) => {
    const responseHeaders = extractResponseHeaders(response)

    if (response.body == null) {
      throw new EmptyResponseBodyError({})
    }

    return {
      responseHeaders,
      value: parseJsonEventStream({
        stream: response.body,
        schema: chunkSchema,
        abortSignal
      })
    }
  }

export const createJsonResponseHandler =
  <T>(responseSchema: FlexibleSchema<T>): ResponseHandler<T> =>
  async ({ response, url, requestBodyValues }) => {
    const responseBody = await readResponseBodyAsText({ response, url })

    const parsedResult = await safeParseJSON({
      text: responseBody,
      schema: responseSchema
    })

    const responseHeaders = extractResponseHeaders(response)

    if (!parsedResult.success) {
      throw new APICallError({
        message: 'Invalid JSON response',
        cause: parsedResult.error,
        statusCode: response.status,
        responseHeaders,
        responseBody,
        url,
        requestBodyValues
      })
    }

    return {
      responseHeaders,
      value: parsedResult.value,
      rawValue: parsedResult.rawValue
    }
  }
