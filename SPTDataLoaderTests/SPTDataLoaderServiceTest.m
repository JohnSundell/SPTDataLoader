/*
 * Copyright (c) 2015 Spotify AB.
 *
 * Licensed to the Apache Software Foundation (ASF) under one
 * or more contributor license agreements.  See the NOTICE file
 * distributed with this work for additional information
 * regarding copyright ownership.  The ASF licenses this file
 * to you under the Apache License, Version 2.0 (the
 * "License"); you may not use this file except in compliance
 * with the License.  You may obtain a copy of the License at
 *
 *   http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing,
 * software distributed under the License is distributed on an
 * "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY
 * KIND, either express or implied.  See the License for the
 * specific language governing permissions and limitations
 * under the License.
 */
#import <XCTest/XCTest.h>

#import "SPTDataLoaderService.h"
#import "SPTDataLoaderRequest.h"
#import "SPTDataLoaderRateLimiter.h"
#import "SPTDataLoaderRequestTaskHandler.h"
#import "SPTDataLoaderResolver.h"
#import "SPTDataLoaderResponse.h"
#import "SPTCancellationToken.h"

#import "SPTDataLoaderRequestResponseHandler.h"
#import "NSURLSessionMock.h"
#import "SPTDataLoaderAuthoriserMock.h"
#import "SPTDataLoaderFactory+Private.h"
#import "SPTDataLoaderRequestResponseHandlerMock.h"
#import "SPTDataLoaderConsumptionObserverMock.h"
#import "NSURLSessionDataTaskMock.h"

@interface SPTDataLoaderService () <NSURLSessionDataDelegate, SPTDataLoaderRequestResponseHandlerDelegate, SPTCancellationTokenDelegate>

@property (nonatomic, strong) NSURLSession *session;
@property (nonatomic, strong) NSMutableArray *handlers;

@end

@interface SPTDataLoaderServiceTest : XCTestCase

@property (nonatomic ,strong) SPTDataLoaderService *service;
@property (nonatomic, strong) SPTDataLoaderRateLimiter *rateLimiter;
@property (nonatomic, strong) SPTDataLoaderResolver *resolver;
@property (nonatomic, strong) NSURLSessionMock *session;

@end

@implementation SPTDataLoaderServiceTest

#pragma mark XCTestCase

- (void)setUp
{
    [super setUp];
    // Put setup code here. This method is called before the invocation of each test method in the class.
    self.rateLimiter = [SPTDataLoaderRateLimiter rateLimiterWithDefaultRequestsPerSecond:10.0];
    self.resolver = [SPTDataLoaderResolver new];
    self.service = [SPTDataLoaderService dataLoaderServiceWithUserAgent:@"Spotify Test 1.0"
                                                            rateLimiter:self.rateLimiter
                                                               resolver:self.resolver
                                               customURLProtocolClasses:nil];
    self.session = [NSURLSessionMock new];
    self.service.session = self.session;
}

- (void)tearDown
{
    // Put teardown code here. This method is called after the invocation of each test method in the class.
    [super tearDown];
}

#pragma mark SPTDataLoaderServiceTest

- (void)testNotNil
{
    XCTAssertNotNil(self.service, @"The service should not be nil after construction");
}

- (void)testFactoryNotNil
{
    SPTDataLoaderFactory *factory = [self.service createDataLoaderFactoryWithAuthorisers:nil];
    XCTAssertNotNil(factory, @"The factory should not be nil after creation from the service");
}

- (void)testNoOperationForTask
{
    // Test no crash occurs
    [self.service URLSession:self.session
                    dataTask:[NSURLSessionDataTask new]
          didReceiveResponse:[NSURLResponse new]
           completionHandler:^(NSURLSessionResponseDisposition disposition){}];
}

- (void)testOperationForTaskWithValidTask
{
    // Test no crash occurs
    SPTDataLoaderRequest *request = [SPTDataLoaderRequest new];
    [self.service requestResponseHandler:nil performRequest:request];
    
    NSURLSessionDataTask *dataTask = self.session.lastDataTask;
    [self.service URLSession:self.session
                    dataTask:dataTask
          didReceiveResponse:[NSURLResponse new]
           completionHandler:^(NSURLSessionResponseDisposition disposition){}];
}

- (void)testResolverChangingAddress
{
    [self.resolver setAddresses:@[ @"192.168.0.1" ] forHost:@"spclient.wg.spotify.com"];
    
    SPTDataLoaderRequest *request = [SPTDataLoaderRequest requestWithURL:[NSURL URLWithString:@"https://spclient.wg.spotify.com/thing"]
                                                        sourceIdentifier:nil];
    [self.service requestResponseHandler:nil performRequest:request];
    XCTAssertEqualObjects(request.URL.absoluteString, @"https://192.168.0.1/thing");
}

- (void)testAuthenticatingRequest
{
    SPTDataLoaderAuthoriserMock *authoriserMock = [SPTDataLoaderAuthoriserMock new];
    SPTDataLoaderFactory *factory = [self.service createDataLoaderFactoryWithAuthorisers:@[ authoriserMock ]];
    SPTDataLoaderRequest *request = [SPTDataLoaderRequest new];
    [self.service requestResponseHandler:factory performRequest:request];
    XCTAssertEqual(authoriserMock.numberOfCallsToAuthoriseRequest, 1, @"The service did not check the requests authorisation");
}

- (void)testRequestAuthorised
{
    // Test no crash occurs on optional delegate method
    [self.service requestResponseHandler:nil authorisedRequest:nil];
}

- (void)testRequestAuthorisationFailed
{
    SPTDataLoaderRequestResponseHandlerMock *requestResponseHandlerMock = [SPTDataLoaderRequestResponseHandlerMock new];
    SPTDataLoaderRequest *request = [SPTDataLoaderRequest new];
    [self.service requestResponseHandler:requestResponseHandlerMock failedToAuthoriseRequest:request error:nil];
    XCTAssertEqual(requestResponseHandlerMock.numberOfFailedResponseCalls, 1, @"The service did not call a failed response on a failed authorisation attempt");
}

- (void)testCancellationTokenCancelsOperation
{
    SPTDataLoaderRequestResponseHandlerMock *requestResponseHandlerMock = [SPTDataLoaderRequestResponseHandlerMock new];
    SPTDataLoaderRequest *request = [SPTDataLoaderRequest new];
    id<SPTCancellationToken> cancellationToken = [self.service requestResponseHandler:requestResponseHandlerMock
                                                                       performRequest:request];
    [cancellationToken cancel];
    XCTAssertEqual(self.session.lastDataTask.numberOfCallsToCancel, 1, @"The service did not call a cancelled request on a cancellation token cancelling");
}

- (void)testSessionDidReceiveResponse
{
    SPTDataLoaderRequest *request = [SPTDataLoaderRequest new];
    [self.service requestResponseHandler:nil performRequest:request];
    
    NSURLSessionDataTask *dataTask = self.session.lastDataTask;
    __block BOOL calledCompletionHandler = NO;
    void (^completionHandler)(NSURLSessionResponseDisposition) = ^(NSURLSessionResponseDisposition disposition) {
        calledCompletionHandler = YES;
    };
    [self.service URLSession:self.session dataTask:dataTask didReceiveResponse:[NSURLResponse new] completionHandler:completionHandler];
    XCTAssertTrue(calledCompletionHandler, @"The service did not call the URL sessions completion handler");
}

- (void)testRedirectionCallbackAbortsTooManyRedirects
{
    SPTDataLoaderRequest *request = [SPTDataLoaderRequest requestWithURL:[NSURL URLWithString:@"https://localhost"]
                                                        sourceIdentifier:@"-"];
    [self.service requestResponseHandler:nil performRequest:request];
    NSURLSessionTask *task = ((SPTDataLoaderRequestTaskHandler *)[self.service.handlers lastObject]).task;

    NSHTTPURLResponse *httpResponse = [[NSHTTPURLResponse alloc] initWithURL:request.URL
                                                                  statusCode:SPTDataLoaderResponseHTTPStatusCodeMovedPermanently
                                                                 HTTPVersion:@"1.1"
                                                                headerFields:@{ }];

    __block BOOL calledCompletionHandler = NO;
    __block BOOL calledCompletionHandlerWithNil = NO;
    void (^completionHandler)(NSURLRequest *) = ^(NSURLRequest *request) {
        calledCompletionHandler = YES;

        if (request == nil) {
            calledCompletionHandlerWithNil = YES;
        } else {
            calledCompletionHandlerWithNil = NO;
        }
    };

    int const redirectsAmountTooMany = 50;

    // Test that redirection is aborted after too many redirects
    for (int i = 0; i <= redirectsAmountTooMany; i++) {
        [self.service URLSession:self.session
                            task:task
      willPerformHTTPRedirection:httpResponse
                      newRequest:[NSURLRequest requestWithURL:[NSURL URLWithString:@"https://localhost"]]
               completionHandler:completionHandler];

        if (calledCompletionHandlerWithNil) {
            break;
        }
    }

    XCTAssertTrue(calledCompletionHandler, @"The service should call the URL redirection completion handler at least once");
    XCTAssertTrue(calledCompletionHandlerWithNil, @"The service should stop redirection after too many redirects");
}

- (void)testRedirectionCallbackDoesNotAbortAfterFewRedirects
{
    SPTDataLoaderRequest *request = [SPTDataLoaderRequest requestWithURL:[NSURL URLWithString:@"https://localhost"]
                                                        sourceIdentifier:@"-"];
    [self.service requestResponseHandler:nil performRequest:request];
    NSURLSessionTask *task = ((SPTDataLoaderRequestTaskHandler *)[self.service.handlers lastObject]).task;

    NSHTTPURLResponse *httpResponse = [[NSHTTPURLResponse alloc] initWithURL:request.URL
                                                                  statusCode:SPTDataLoaderResponseHTTPStatusCodeMovedPermanently
                                                                 HTTPVersion:@"1.1"
                                                                headerFields:@{ }];

    __block BOOL calledCompletionHandler = NO;
    __block BOOL calledCompletionHandlerWithNil = NO;
    void (^completionHandler)(NSURLRequest *) = ^(NSURLRequest *request) {
        calledCompletionHandler = YES;

        if (request == nil) {
            calledCompletionHandlerWithNil = YES;
        } else {
            calledCompletionHandlerWithNil = NO;
        }
    };

    int const redirectsAmountFew = 2;

    // Check that just a few redirects will work fine
    for (int i = 0; i <= redirectsAmountFew; i++) {
        [self.service URLSession:self.session
                            task:task
      willPerformHTTPRedirection:httpResponse
                      newRequest:[NSURLRequest requestWithURL:[NSURL URLWithString:@"https://localhost"]]
               completionHandler:completionHandler];
    }

    XCTAssertTrue(calledCompletionHandler, @"The service should call the URL redirection completion handler at least once");
    XCTAssertFalse(calledCompletionHandlerWithNil, @"The service should not stop redirection after too few redirects");
}

- (void)testSwitchingToDownloadTask
{
    // Test no crash
    [self.service URLSession:self.service.session dataTask:[NSURLSessionDataTask new] didBecomeDownloadTask:[NSURLSessionDownloadTask new]];
}

- (void)testSessionDidReceiveData
{
    SPTDataLoaderRequestResponseHandlerMock *requestResponseHandlerMock = [SPTDataLoaderRequestResponseHandlerMock new];
    SPTDataLoaderRequest *request = [SPTDataLoaderRequest new];
    request.chunks = YES;
    [self.service requestResponseHandler:requestResponseHandlerMock performRequest:request];
    NSData *data = [@"thing" dataUsingEncoding:NSUTF8StringEncoding];
    [self.service URLSession:self.service.session dataTask:self.session.lastDataTask didReceiveData:data];
    XCTAssertEqual(requestResponseHandlerMock.numberOfReceivedDataRequestCalls, 1, @"The service did not call received data on the request response handler");
}

- (void)testSessionDidComplete
{
    SPTDataLoaderRequestResponseHandlerMock *requestResponseHandlerMock = [SPTDataLoaderRequestResponseHandlerMock new];
    SPTDataLoaderRequest *request = [SPTDataLoaderRequest new];
    [self.service requestResponseHandler:requestResponseHandlerMock performRequest:request];
    [self.service URLSession:self.session task:self.session.lastDataTask didCompleteWithError:nil];
    XCTAssertEqual(requestResponseHandlerMock.numberOfSuccessfulDataResponseCalls, 1, @"The service did not call successfully received response on the request response handler");
}

- (void)testSessionWillCacheResponse
{
    SPTDataLoaderRequest *request = [SPTDataLoaderRequest new];
    request.skipNSURLCache = NO;
    
    [self.service requestResponseHandler:nil performRequest:request];
    NSCachedURLResponse *dummyResponse = [NSCachedURLResponse new];
    
    __block NSCachedURLResponse *blockResponse = nil;
    void (^completion)(NSCachedURLResponse *) = ^(NSCachedURLResponse *resp) {
        blockResponse = resp;
    };
    [self.service URLSession:self.session dataTask:self.session.lastDataTask willCacheResponse:dummyResponse completionHandler:completion];
    XCTAssertNotNil(blockResponse, @"The service skipped caching when 'skipNSURLCache' was set to NO");
}

- (void)testSessionWillNotCacheResponse
{
    SPTDataLoaderRequest *request = [SPTDataLoaderRequest new];
    request.skipNSURLCache = YES;
    
    [self.service requestResponseHandler:nil performRequest:request];
    NSCachedURLResponse *dummyResponse = [NSCachedURLResponse new];
    
    __block NSCachedURLResponse *blockResponse = nil;
    void (^completion)(NSCachedURLResponse *) = ^(NSCachedURLResponse *resp) {
        blockResponse = resp;
    };
    [self.service URLSession:self.session dataTask:self.session.lastDataTask willCacheResponse:dummyResponse completionHandler:completion];
    XCTAssertNil(blockResponse, @"The service failed to skip the cache when 'skipNSURLCache' was set to YES");
}

- (void)testConsumptionObserverCalled
{
    SPTDataLoaderConsumptionObserverMock *consumptionObserver = [SPTDataLoaderConsumptionObserverMock new];
    [self.service addConsumptionObserver:consumptionObserver on:dispatch_get_main_queue()];
    [self.service URLSession:self.session task:[NSURLSessionDataTaskMock new] didCompleteWithError:nil];
    XCTAssertEqual(consumptionObserver.numberOfCallsToEndedRequest, 1, @"There should be 1 call to the consumption observer when a request ends");
    [self.service removeConsumptionObserver:consumptionObserver];
    [self.service URLSession:self.session task:[NSURLSessionDataTaskMock new] didCompleteWithError:nil];
    XCTAssertEqual(consumptionObserver.numberOfCallsToEndedRequest, 1, @"There should be 1 call to the consumption observer when the observer has been removed");
}

@end
