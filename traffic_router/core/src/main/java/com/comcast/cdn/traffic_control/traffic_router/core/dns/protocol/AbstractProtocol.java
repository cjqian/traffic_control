/*
 * Copyright 2015 Comcast Cable Communications Management, LLC
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *     http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

package com.comcast.cdn.traffic_control.traffic_router.core.dns.protocol;

import java.net.InetAddress;
import java.util.Date;
import java.util.concurrent.ExecutorService;

import org.xbill.DNS.Message;
import org.xbill.DNS.Rcode;
import org.xbill.DNS.Section;
import org.xbill.DNS.WireParseException;

import com.comcast.cdn.traffic_control.traffic_router.core.dns.DNSAccessRecord;
import com.comcast.cdn.traffic_control.traffic_router.core.dns.NameServer;

public abstract class AbstractProtocol implements Protocol {
    private static final int NUM_SECTIONS = 4;

    protected boolean shutdownRequested;
    private ExecutorService executorService;
    private NameServer nameServer;

    /**
     * Gets executorService.
     * 
     * @return the executorService
     */
    public ExecutorService getExecutorService() {
        return executorService;
    }

    /**
     * Gets nameServer.
     * 
     * @return the nameServer
     */
    public NameServer getNameServer() {
        return nameServer;
    }

    /**
     * Sets executorService.
     * 
     * @param executorService
     *            the executorService to set
     */
    public void setExecutorService(final ExecutorService executorService) {
        this.executorService = executorService;
    }

    /**
     * Sets nameServer.
     * 
     * @param nameServer
     *            the nameServer to set
     */
    public void setNameServer(final NameServer nameServer) {
        this.nameServer = nameServer;
    }

    @Override
    public void shutdown() {
        shutdownRequested = true;
        executorService.shutdownNow();
    }

    /**
     * Returns the maximum length of the response.
     * 
     * @param the
     *            request message
     * @return the maximum length in bytes
     */
    protected abstract int getMaxResponseLength(Message request);

    /**
     * Gets shutdownRequested.
     * 
     * @return the shutdownRequested
     */
    protected boolean isShutdownRequested() {
        return shutdownRequested;
    }

    /**
     * Queries the DNS nameServer and returns the response.
     * 
     * @param client
     *            the IP address of the client
     * @param request
     *            the DNS request in wire format
     * @return the DNS response in wire format
     */
    protected byte[] query(final InetAddress client, final byte[] request) {
        final DNSAccessRecord record = new DNSAccessRecord();
        record.setRequestDate(new Date());
        record.setClient(client);
        Message query = null;
        Message response = null;
        try {
            query = new Message(request);
            record.setRequest(query);
            response = getNameServer().query(query, client);
            record.setResponse(response);
        } catch (final WireParseException e) {
            throw new IllegalArgumentException(e);
        } catch (final Exception e) {
            response = createServerFail(query);
        } finally {
            record.log();
        }

        return response.toWire(getMaxResponseLength(query));
    }

    /**
     * Submits a request handler to be executed.
     * 
     * @param job
     *            the handler to be executed
     */
    protected void submit(final Runnable job) {
        executorService.submit(job);
    }

    private Message createServerFail(final Message query) {
        final Message response = new Message();
        if (query != null) {
            response.setHeader(query.getHeader());
            // This has the side effect of clearing counts out of the header
            for (int i = 0; i < NUM_SECTIONS; i++) {
                response.removeAllRecords(i);
            }
            response.addRecord(query.getQuestion(), Section.QUESTION);
        }
        response.getHeader().setRcode(Rcode.SERVFAIL);
        return response;
    }
}
