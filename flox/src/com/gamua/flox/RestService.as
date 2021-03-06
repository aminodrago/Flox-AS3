// =================================================================================================
//
//	Flox AS3
//	Copyright 2012 Gamua OG. All Rights Reserved.
//
// =================================================================================================

package com.gamua.flox
{
    import com.gamua.flox.events.QueueEvent;
    import com.gamua.flox.utils.Base64;
    import com.gamua.flox.utils.DateUtil;
    import com.gamua.flox.utils.HttpMethod;
    import com.gamua.flox.utils.HttpStatus;
    import com.gamua.flox.utils.cloneObject;
    import com.gamua.flox.utils.createURL;
    import com.gamua.flox.utils.execute;
    import com.gamua.flox.utils.setTimeout;
    
    import flash.events.Event;
    import flash.events.EventDispatcher;
    import flash.events.HTTPStatusEvent;
    import flash.events.IOErrorEvent;
    import flash.net.URLLoader;
    import flash.net.URLRequest;
    import flash.net.URLRequestMethod;
    import flash.net.URLVariables;
    import flash.utils.ByteArray;

    /** A class that makes it easy to communicate with the Flox server via a REST protocol. */
    internal class RestService extends EventDispatcher
    {
        private var mUrl:String;
        private var mGameID:String;
        private var mGameKey:String;
        private var mQueue:PersistentQueue;
        private var mCache:PersistentStore;
        private var mAlwaysFail:Boolean;
        private var mProcessingQueue:Boolean;
        
        /** Helper objects */
        private static var sBuffer:ByteArray = new ByteArray();
        
        /** Create an instance with the base URL of the Flox service. The class will allow 
         *  communication with the entities of a certain game (identified by id and key). */
        public function RestService(url:String, gameID:String, gameKey:String)
        {
            mUrl = url;
            mGameID = gameID;
            mGameKey = gameKey;
            mAlwaysFail = false;
            mProcessingQueue = false;
            mQueue = new PersistentQueue("Flox.RestService.queue." + gameID);
            mCache = new PersistentStore("Flox.RestService.cache." + gameID);
        }
        
        /** Makes an asynchronous HTTP request at the server, with custom authentication data. */
        private function requestWithAuthentication(method:String, path:String, data:Object, 
                                                   authentication:Authentication,
                                                   onComplete:Function, onError:Function):void
        {
            if (authentication == null)
            {
                // This is only null while a login is in process. To avoid problems with player
                // authentication, we do not allow that to happen. The error callback is executed
                // with a delay so that the method acts the same way as if this was a server error.
                
                setTimeout(execute, 1, onError, "Cannot make request while login is in process",
                                       HttpStatus.FORBIDDEN);
                return;
            }
            
            if (method == HttpMethod.GET && data)
            {
                path += "?" + encodeForUri(data);
                data = null;
            }
            
            var eTag:String;
            var cachedResult:Object = null;
            var headers:Object = {};
            var xFloxHeader:Object = {
                sdk: { 
                    type: "as3", 
                    version: Flox.VERSION
                },
                player: { 
                    id:        authentication.playerId,
                    authType:  authentication.type,
                    authId:    authentication.id,
                    authToken: authentication.token
                },
                gameKey: mGameKey,
                bodyCompression: "zlib",
                dispatchTime: DateUtil.toString(new Date())
            };
            
            headers["Content-Type"] = "application/json";
            headers["X-Flox"] = xFloxHeader;
            
            if (mCache.containsKey(path) && (method == HttpMethod.GET || method == HttpMethod.PUT))
            {
                eTag = mCache.getMetaData(path, "eTag") as String;
                cachedResult = mCache.getObject(path);

                if (cachedResult)
                {
                    if (method == HttpMethod.GET) headers["If-None-Match"] = eTag;
                    else if (method == HttpMethod.PUT) headers["If-Match"] = eTag;
                }
            }
            
            if (mAlwaysFail)
            {
                setTimeout(execute, 1, onError, "forced failure", 0, cachedResult);
                return;
            }

            var loader:URLLoader = new URLLoader();
            loader.addEventListener(Event.COMPLETE, onLoaderComplete);
            loader.addEventListener(IOErrorEvent.IO_ERROR, onLoaderError);
            loader.addEventListener(HTTPStatusEvent.HTTP_STATUS, onLoaderHttpStatus);
            
            var httpStatus:int = -1;
            var url:String = createURL("/api/games", mGameID, path);
            var request:URLRequest = new URLRequest(mUrl);
            var requestData:Object = { 
                method: method, url: url, headers: headers, body: encode(data) 
            };
            
            request.method = URLRequestMethod.POST;
            request.data = JSON.stringify(requestData);
            
            loader.load(request);
            
            function onLoaderComplete(event:Event):void
            {
                closeLoader();
                
                if (httpStatus != HttpStatus.OK)
                {
                    execute(onError, "Flox Server unreachable", httpStatus, cachedResult);
                }
                else
                {
                    try
                    {
                        var response:Object = JSON.parse(loader.data);
                        var status:int = parseInt(response.status);
                        var headers:Object = response.headers;
                        var body:Object = getBodyFromResponse(response);
                    }
                    catch (e:Error)
                    {
                        execute(onError, "Invalid response from Flox server: " + e.message,
                                httpStatus, cachedResult);
                        return;
                    }
                    
                    if (status < 400) // success =)
                    {
                        var result:Object = body;
                        
                        if (method == HttpMethod.GET)
                        {
                            if (status == HttpStatus.NOT_MODIFIED)
                                result = cachedResult;
                            else
                                mCache.setObject(path, body, { eTag: headers.ETag });
                        }
                        else if (method == HttpMethod.PUT)
                        {
                            if ("createdAt" in result && "updatedAt" in result)
                            {
                                data = cloneObject(data);
                                data.createdAt = result.createdAt;
                                data.updatedAt = result.updatedAt;
                            }
                            
                            mCache.setObject(path, data, { eTag: headers.ETag });
                        }
                        else if (method == HttpMethod.DELETE)
                        {
                            mCache.removeObject(path);
                        }
                        
                        execute(onComplete, result, status);
                    }
                    else // error =(
                    {
                        var error:String = (body && body.message) ? body.message : "unknown";
                        execute(onError, error, status, cachedResult);
                    }
                }
            }
            
            function onLoaderError(event:IOErrorEvent):void
            {
                closeLoader();
                execute(onError, "IO " + event.text, httpStatus, cachedResult);
            }
            
            function onLoaderHttpStatus(event:HTTPStatusEvent):void
            {
                httpStatus = event.status;
            }
            
            function closeLoader():void
            {
                loader.removeEventListener(Event.COMPLETE, onLoaderComplete);
                loader.removeEventListener(IOErrorEvent.IO_ERROR, onLoaderError);
                loader.removeEventListener(HTTPStatusEvent.HTTP_STATUS, onLoaderHttpStatus);
                loader.close();
            }
        }
        
        /** Makes an asynchronous HTTP request at the server. Before doing that, it will always
         *  process the request queue. If that fails with a non-transient error, this request
         *  will fail as well. The method will always execute exactly one of the provided callback
         *  functions.
         *  
         *  @param method  one of the constants provided by the 'HttpMethod' class.
         *  @param path  the path of the resource relative to the root of the game (!).
         *  @param data  the data that will be sent as JSON-encoded body or as URL parameters
         *               (depending on the http method).
         *  @param onComplete  a callback with the form:
         *                     <pre>onComplete(body:Object, httpStatus:int):void;</pre>
         *  @param onError     a callback with the form:
         *                     <pre>onError(error:String, httpStatus:int, cachedBody:Object):void;</pre>
         */
        public function request(method:String, path:String, data:Object, 
                                onComplete:Function, onError:Function):void
        {
            // might change before we're in the event handler!
            var auth:Authentication = Flox.authentication;
            
            if (processQueue())
            {
                addEventListener(QueueEvent.QUEUE_PROCESSED, 
                    function onQueueProcessed(event:QueueEvent):void
                    {
                        removeEventListener(QueueEvent.QUEUE_PROCESSED, onQueueProcessed);
                        
                        if (event.success)
                            requestWithAuthentication(method, path, data, auth,
                                                      onComplete, onError);
                        else
                            execute(onError, event.error, event.httpStatus,
                                    method == HttpMethod.GET ? getFromCache(path, data) : null);
                    });
            }
            else
            {
                requestWithAuthentication(method, path, data, auth, onComplete, onError);
            }
        }
        
        /** Adds an asynchronous HTTP request to a queue and immediately starts to process the
         *  queue. */
        public function requestQueued(method:String, path:String, data:Object=null):void
        {
            var queueLength:int;
            var metaData:String = null;
            
            if (method == HttpMethod.PUT)
            {
                // To allow developers to use Flox offline, we're optimistic here:
                // even though the operation might fail, we're saving the object in the cache.
                mCache.setObject(path, data);
                
                // if PUT is called repeatedly for the same resource (path),
                // we only need to keep the newest one.
                metaData = "PUT#" + path;
                queueLength = mQueue.length;
                
                mQueue.filter(function(i:int, m:String):Boolean
                {
                    if (i == queueLength-1) return true; // last element might be processed already
                    else return metaData != m;
                });
            }

            var auth:Authentication = Flox.authentication;
            var request:Object = { method: method, path: path, data: data, authentication: auth };
            mQueue.enqueue(request, metaData);
            processQueue();
        }
        
        /** Processes the request queue, executing requests in the order they were recorded.
         *  If the server cannot be reached, processing stops and is retried later; if a request
         *  produces an error, it is discarded. 
         *  @returns true if the queue is currently being processed. */
        public function processQueue():Boolean
        {
            if (!mProcessingQueue)
            {
                var auth:Authentication;
                var element:Object = mQueue.peek();
                
                if (element != null)
                {
                    mProcessingQueue = true;
                    auth = element.authentication as Authentication;
                    requestWithAuthentication(element.method, element.path, element.data, 
                                              auth, onRequestComplete, onRequestError);
                }
                else 
                {
                    mProcessingQueue = false;
                    dispatchEvent(new QueueEvent(QueueEvent.QUEUE_PROCESSED));
                }
            }
            
            return mProcessingQueue;
            
            function onRequestComplete(body:Object, httpStatus:int):void
            {
                mProcessingQueue = false;
                mQueue.dequeue();
                processQueue();
            }
            
            function onRequestError(error:String, httpStatus:int):void
            {
                mProcessingQueue = false;
                
                if (HttpStatus.isTransientError(httpStatus))
                {
                    // server did not answer or is not available! we stop queue processing.
                    Flox.logInfo("Flox Server not reachable (device probably offline). " + 
                                 "HttpStatus: {0}", httpStatus);
                    dispatchEvent(new QueueEvent(QueueEvent.QUEUE_PROCESSED, httpStatus, error));
                }
                else
                {
                    // server answered, but there was a logic error -> no retry
                    Flox.logWarning("Flox service queue request failed: {0}, HttpStatus: {1}", 
                                    error, httpStatus);
                    
                    mQueue.dequeue();
                    processQueue();
                }
            }
        }
        
        /** Saves request queue and cache index to the disk. */
        public function flush():void
        {
            mQueue.flush();
            mCache.flush();
        }
        
        /** Clears the persistent queue. */
        public function clearQueue():void
        {
            mQueue.clear();
        }
        
        /** Clears the persistent cache. */
        public function clearCache():void
        {
            mCache.clear();
        }
        
        /** Returns an object that was previously received with a GET method from the cache.
         *  If 'data' is given, it is URL-encoded and added to the path.
         *  If 'eTag' is given, it must match the object's eTag; otherwise,
         *  the method returns null. */
        public function getFromCache(path:String, data:Object=null, eTag:String=null):Object
        {
            if (data) path += "?" + encodeForUri(data);
            if (mCache.containsKey(path))
            {
                var cachedObject:Object = mCache.getObject(path);
                var cachedETag:String = mCache.getMetaData(path, "eTag") as String;
                
                if (eTag == null || eTag == cachedETag)
                    return cachedObject;
            }
            return null;
        }
        
        // object encoding
        
        /** Encodes an object as parameters for a 'GET' request. */
        private static function encodeForUri(object:Object):String
        {
            var urlVariables:URLVariables = new URLVariables();
            for (var key:String in object) urlVariables[key] = object[key];
            return urlVariables.toString();
        }
        
        /** Encodes an object in JSON format, compresses it and returns its Base64 representation. */
        private static function encode(object:Object):String
        {
            sBuffer.writeUTFBytes(JSON.stringify(object, null, 0));
            sBuffer.compress();
            
            var encodedData:String = Base64.encodeByteArray(sBuffer);
            sBuffer.length = 0;
            
            return encodedData;
        }
        
        /** Decodes an object from JSON format, compressed in a Base64-encoded, zlib-compressed
         *  String. */
        private static function decode(string:String):Object
        {
            if (string == null || string == "") return null;
            
            Base64.decodeToByteArray(string, sBuffer);
            sBuffer.uncompress();
            
            var json:String = sBuffer.readUTFBytes(sBuffer.length);
            sBuffer.length = 0;
            
            return JSON.parse(json);
        }
        
        /** Retrieves the body from the server response, optionally decompressing its
         *  JSON contents (if suggested by header). */
        private static function getBodyFromResponse(response:Object):Object
        {
            var body:Object = null;
            var headers:Object = response.headers;
            var compression:String = "none";
            
            if (headers)
            {
                if ("X-Content-Encoding" in headers)  compression = headers["X-Content-Encoding"];
                else if ("Content-Encoding" in headers) compression = headers["Content-Encoding"];
            }
            
            if (compression == "zlib")
                body = decode(response.body);
            else if (compression == "none")
                body = response.body;
            else
                throw new Error("Invalid body compression: " + compression);
            
            return body;
        }
        
        // properties
        
        /** @private 
         *  If enabled, all requests will fail. Useful only for unit testing. */
        internal function get alwaysFail():Boolean { return mAlwaysFail; }
        internal function set alwaysFail(value:Boolean):void { mAlwaysFail = value; }
        
        /** The URL pointing to the Flox REST API. */
        public function get url():String { return mUrl; }
        
        /** The unique ID of the game. */
        public function get gameID():String { return mGameID; }
        
        /** The key that identifies the game. */
        public function get gameKey():String { return mGameKey; }
        
        /** Indicates if the connection should be encryped using SSL/TLS. */
        public function get useSecureConnection():Boolean
        {
            return mUrl.toLowerCase().indexOf("https") == 0;
        }
        
        public function set useSecureConnection(value:Boolean):void
        {
            mUrl = mUrl.replace(/^http[s]?/, value ? "https" : "http");
        }
    }
}