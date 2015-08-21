// Copyright (c) 2014, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

part of rpc.config;

final _bytesToJson = UTF8.decoder.fuse(JSON.decoder);

class ApiConfigMethod {
  final Symbol symbol;
  final String id;
  final String name;
  final String path;
  final String httpMethod;
  final String description;
  final List<ApiConfigMethodPlugin> enablePlugins;

  final InstanceMirror _instance;
  final List<ApiParameter> _pathParams;
  final List<ApiParameter> _queryParams;
  final ApiConfigSchema _requestSchema;
  final ApiConfigSchema _responseSchema;
  final UriParser _parser;

  ApiConfigMethod(this.id, this._instance, this.symbol, this.name, this.path,
                  this.httpMethod, this.description, this.enablePlugins,
                  this._pathParams, this._queryParams, this._requestSchema,
                  this._responseSchema, this._parser);

  bool matches(ParsedHttpApiRequest request) {
    UriMatch match = _parser.match(request.methodUri);
    if (match == null) {
      return false;
    }
    assert(match.rest.path.length == 0);
    request.pathParameters = match.parameters;
    return true;
  }

  discovery.RestMethod get asDiscovery {
    var method = new discovery.RestMethod();
    method..id = id
          ..path = path
          ..httpMethod = httpMethod.toUpperCase()
          ..description = description
          ..parameterOrder = _pathParams.map((param) => param.name).toList();
    method.parameters = new Map<String, discovery.JsonSchema>();
    _pathParams.forEach((param) {
      var schema = new discovery.JsonSchema();
      schema..type = param.isInt ? discovery.JsonSchema.PARAM_INTEGER_TYPE
                                 : (param.isBool ? discovery.JsonSchema.PARAM_BOOL_TYPE : discovery.JsonSchema.PARAM_STRING_TYPE)
            ..required = true
            ..description = 'Path parameter: \'${param.name}\'.'
            ..location = discovery.JsonSchema.PARAM_LOCATION_PATH;
      method.parameters[param.name] = schema;
    });
    if (_queryParams != null) {
      _queryParams.forEach((param) {
        var schema = new discovery.JsonSchema();
        schema..type = param.isInt ? discovery.JsonSchema.PARAM_INTEGER_TYPE
                                   : (param.isBool ? discovery.JsonSchema.PARAM_BOOL_TYPE : discovery.JsonSchema.PARAM_STRING_TYPE)
              ..required = false
              ..description = 'Query parameter: \'${param.name}\'.'
              ..location = discovery.JsonSchema.PARAM_LOCATION_QUERY;
        method.parameters[param.name] = schema;
      });
    }
    if (_requestSchema != null && _requestSchema.containsData) {
      method.request =
          new discovery.RestMethodRequest()..P_ref = _requestSchema.schemaName;
    }
    if (_responseSchema != null && _responseSchema.containsData) {
      method.response = new discovery.RestMethodResponse()
                            ..P_ref = _responseSchema.schemaName;
    }
    return method;
  }

  Future<HttpApiResponse> invokeHttpRequest(
      ParsedHttpApiRequest request) async {
    List<dynamic> positionalParams = [];
    // Add path parameters to params in the correct order.
    assert(_pathParams != null);
    assert(request.pathParameters != null);
    for (int i = 0; i < _pathParams.length; ++i) {
      var param = _pathParams[i];
      var value = request.pathParameters[param.name];
      if (value == null) {
        return httpErrorResponse(request.originalRequest,
            new BadRequestError('Required parameter: ${param.name} missing.'));
      }
      if (param.isInt) {
        try {
          positionalParams.add(int.parse(value));
        } on FormatException catch (error, stack) {
          return httpErrorResponse(request.originalRequest,
              new BadRequestError('Invalid integer value: $value for '
                                  'path parameter: ${param.name}. '
                                  '${error.toString()}'), stack: stack);
        }
      } else if(param.isBool){
          positionalParams.add(value == 'true');
      } else {
        positionalParams.add(value);
      }
    }
    // Build named parameter map for query parameters.
    Map<Symbol, dynamic> namedParams = {};
    if (_queryParams != null && request.queryParameters != null) {
      for (int i = 0; i < _queryParams.length; ++i) {
        var param = _queryParams[i];
        // Check if there is a parameter value for the given name.
        var value = request.queryParameters[param.name];
        if (value != null) {
          if (param.isInt) {
            try {
              namedParams[param.symbol] = int.parse(value);
            } on FormatException catch (error, stack) {
              return httpErrorResponse(request.originalRequest,
                  new BadRequestError('Invalid integer value: $value for '
                                      'query parameter: ${param.name}. '
                                      '${error.toString()}'), stack: stack);
            }
          } else if(param.isBool){
              namedParams[param.symbol] = value == 'true';
          } else {
            namedParams[param.symbol] = value;
          }
        }
        // We ignore query parameters that don't match a named method
        // parameter.
      }
    }
    // We run the entire invocation and creation of the httpApiResponse inside
    // a separate scope containing the invocation context. This allows the
    // implementor of the API to see the current request's headers, url, etc.
    // and to provide response headers and possibly other (future) values to be
    // used in the response.
    return ss.fork(() async {
      ss.register(INVOCATION_CONTEXT, new InvocationContext(request));

      var apiResult;
      try {
        if (bodyLessMethods.contains(httpMethod)) {
          apiResult =
              await invokeNoBody(request, positionalParams, namedParams);
        } else {
          apiResult =
              await invokeWithBody(request, positionalParams, namedParams);
        }
      } on RpcError catch (error, stack) {
        // Catch RpcError explicitly and wrap them in the http error response.
        return httpErrorResponse(request.originalRequest, error, stack: stack,
                                 drainRequest: false);
      } catch (error, stack) {
        // All other exceptions thrown are caught and wrapped as
        // ApplicationError with status code 500. Otherwise these exceptions
        // would be shown as Unknown API Error since we cannot distinguish them
        // from e.g. an internal null pointer exception.
        return httpErrorResponse(request.originalRequest,
            new ApplicationError(error), stack: stack, drainRequest: false);
      }
      rpcLogger.fine('Method returned result: $apiResult');
      var resultAsJson = {};
      var resultBody;
      var statusCode;
      if (_responseSchema != null && _responseSchema.containsData) {
        if (apiResult == null) {
          // We don't allow for method to return null if they have specified a
          // response schema. Log the error and return internal server error to
          // client.
          rpcLogger.warning(
              'Method $name returned null instead of valid return value');
          return httpErrorResponse(
              request.originalRequest,
              new InternalServerError(
                  'Method with non-void return type returned \'null\''),
              drainRequest: false);
        }
        resultAsJson = _responseSchema.toResponse(apiResult);
        rpcLogger.finest('Successfully encoded result as json: $resultAsJson');
        var resultAsBytes = request.jsonToBytes.convert(resultAsJson);
        rpcLogger.finest(
            'Successfully encoded json as bytes:\n  $resultAsBytes');
        resultBody = new Stream.fromIterable([resultAsBytes]);
        statusCode = HttpStatus.OK;
      } else {
        // Return an empty stream.
        resultBody = new Stream.fromIterable([]);
        statusCode = HttpStatus.NO_CONTENT;
      }
      // If the api method has set a specific response status code use that
      // instead of the above default based on the result content.
      if (context.responseStatusCode != null) {
        statusCode = context.responseStatusCode;
      }
      var response =
          new HttpApiResponse(statusCode, resultBody, context.responseHeaders);
      logResponse(response, resultAsJson);
      return response;
    });
  }

  Future<dynamic> invokeNoBody(ParsedHttpApiRequest request,
                               List<dynamic> positionalParams,
                               Map<Symbol, dynamic> namedParams) async {
    // Drain the request body just in case.
    await request.body.drain();
    logRequest(request, null);
    logMethodInvocation(symbol, positionalParams, namedParams);

    // Plugin managment
    for (var plugin in this.enablePlugins) {
      if (ApiConfigMethodPlugin.plugins[plugin.pluginName] != null) {
        var res = await ApiConfigMethodPlugin.plugins[plugin.pluginName](request, positionalParams, namedParams, plugin.additionalParameters);
        if (res != null)
          return res;
      }
    }

    return _instance.invoke(symbol, positionalParams, namedParams).reflectee;
  }

  Future<dynamic> invokeWithBody(ParsedHttpApiRequest request,
                                 List<dynamic> positionalParams,
                                 Map<Symbol, dynamic> namedParams) async {
    assert(_requestSchema != null);
    // Decode request body parameters to json.
    // TODO: support other encodings
    var decodedRequest = {};
    try {
      if (_requestSchema.containsData) {
        decodedRequest = await request.body.transform(_bytesToJson).first;
        logRequest(request, decodedRequest);
      }
      // The request schema is the last positional parameter, so just adding
      // it to the list of position parameters.
      positionalParams.add(_requestSchema.fromRequest(decodedRequest));
    } catch (error) {
      rpcLogger.warning('Failed to decode request body: $error');
      if (error is FormatException) {
        if (error.message == 'Unexpected end of input') {
          // The method expects a body and none was passed.
          throw new BadRequestError(
              'Method \'$name\' requires an instance of '
              '${_requestSchema.schemaName}. Passing the empty request is not '
              'supported.');
        }
      } else if (error is RpcError) {
        throw error;
      }
      throw new BadRequestError(
            'Failed to decode request with internal error: $error');
    }
    logMethodInvocation(symbol, positionalParams, namedParams);

    // Plugin managment
    for (var plugin in this.enablePlugins) {
      if (ApiConfigMethodPlugin.plugins[plugin.pluginName] != null) {
        var res = await ApiConfigMethodPlugin.plugins[plugin.pluginName](request, positionalParams, namedParams, plugin.additionalParameters);
        if (res != null)
          return res;
      }
    }

    return _instance.invoke(symbol, positionalParams, namedParams).reflectee;
  }
}
