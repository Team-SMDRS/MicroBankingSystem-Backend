CREATE INDEX idx_account_account_no ON public.account USING btree (account_no);


--
-- TOC entry 3498 (class 1259 OID 31195)
-- Name: idx_account_branch_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_account_branch_id ON public.account USING btree (branch_id);


--
-- TOC entry 3503 (class 1259 OID 31196)
-- Name: idx_audit_log_table_record; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_audit_log_table_record ON public.audit_log USING btree (table_name, record_id);


--
-- TOC entry 3504 (class 1259 OID 31197)
-- Name: idx_audit_log_timestamp; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_audit_log_timestamp ON public.audit_log USING btree ("timestamp");


--
-- TOC entry 3505 (class 1259 OID 31198)
-- Name: idx_audit_log_user_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_audit_log_user_id ON public.audit_log USING btree (user_id);


--
-- TOC entry 3512 (class 1259 OID 31199)
-- Name: idx_customer_created_at; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_customer_created_at ON public.customer USING btree (created_at);


--
-- TOC entry 3513 (class 1259 OID 31469)
-- Name: idx_customer_nic; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_customer_nic ON public.customer USING btree (nic);


--
-- TOC entry 3526 (class 1259 OID 31201)
-- Name: idx_login_time; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_login_time ON public.login USING btree (login_time);


--
-- TOC entry 3527 (class 1259 OID 31202)
-- Name: idx_login_user_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_login_user_id ON public.login USING btree (user_id);


--
-- TOC entry 3536 (class 1259 OID 31203)
-- Name: idx_transactions_acc_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_transactions_acc_id ON public.transactions USING btree (acc_id);


--
-- TOC entry 3537 (class 1259 OID 31204)
-- Name: idx_transactions_created_at; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_transactions_created_at ON public.transactions USING btree (created_at);


--
-- TOC entry 3538 (class 1259 OID 31205)
-- Name: idx_transactions_type; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_transactions_type ON public.transactions USING btree (type);


--
-- TOC entry 3549 (class 1259 OID 31206)
-- Name: idx_user_refresh_tokens_expires_at; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_user_refresh_tokens_expires_at ON public.user_refresh_tokens USING btree (expires_at);


--
-- TOC entry 3550 (class 1259 OID 31207)
-- Name: idx_user_refresh_tokens_hash; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_user_refresh_tokens_hash ON public.user_refresh_tokens USING btree (token_hash);


--
-- TOC entry 3551 (class 1259 OID 31208)
-- Name: idx_user_refresh_tokens_revoked; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_user_refresh_tokens_revoked ON public.user_refresh_tokens USING btree (is_revoked);


--
-- TOC entry 3552 (class 1259 OID 31209)
-- Name: idx_user_refresh_tokens_user_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_user_refresh_tokens_user_id ON public.user_refresh_tokens USING btree (user_id);


--
-- TOC entry 3555 (class 1259 OID 31210)
-- Name: idx_users_created_at; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_users_created_at ON public.users USING btree (created_at);


--
-- TOC entry 3556 (class 1259 OID 31211)
-- Name: idx_users_nic; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_users_nic ON public.users USING btree (nic);

