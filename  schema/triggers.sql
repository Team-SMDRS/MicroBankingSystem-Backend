CREATE TRIGGER update_account_updated_at BEFORE UPDATE ON public.account FOR EACH ROW EXECUTE FUNCTION public.update_updated_at_column();


--
-- TOC entry 3602 (class 2620 OID 31213)
-- Name: branch update_branch_updated_at; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER update_branch_updated_at BEFORE UPDATE ON public.branch FOR EACH ROW EXECUTE FUNCTION public.update_updated_at_column();


--
-- TOC entry 3604 (class 2620 OID 31214)
-- Name: customer_login update_customer_login_updated_at; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER update_customer_login_updated_at BEFORE UPDATE ON public.customer_login FOR EACH ROW EXECUTE FUNCTION public.update_updated_at_column();


--
-- TOC entry 3603 (class 2620 OID 31215)
-- Name: customer update_customer_updated_at; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER update_customer_updated_at BEFORE UPDATE ON public.customer FOR EACH ROW EXECUTE FUNCTION public.update_updated_at_column();


--
-- TOC entry 3605 (class 2620 OID 31216)
-- Name: fd_plan update_fd_plan_updated_at; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER update_fd_plan_updated_at BEFORE UPDATE ON public.fd_plan FOR EACH ROW EXECUTE FUNCTION public.update_updated_at_column();


--
-- TOC entry 3606 (class 2620 OID 31217)
-- Name: fixed_deposit update_fixed_deposit_updated_at; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER update_fixed_deposit_updated_at BEFORE UPDATE ON public.fixed_deposit FOR EACH ROW EXECUTE FUNCTION public.update_updated_at_column();


--
-- TOC entry 3607 (class 2620 OID 31218)
-- Name: savings_plan update_savings_plan_updated_at; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER update_savings_plan_updated_at BEFORE UPDATE ON public.savings_plan FOR EACH ROW EXECUTE FUNCTION public.update_updated_at_column();


--
-- TOC entry 3608 (class 2620 OID 31219)
-- Name: user_login update_user_login_updated_at; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER update_user_login_updated_at BEFORE UPDATE ON public.user_login FOR EACH ROW EXECUTE FUNCTION public.update_updated_at_column();


--
-- TOC entry 3610 (class 2620 OID 31220)
-- Name: user_refresh_tokens update_user_refresh_tokens_updated_at; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER update_user_refresh_tokens_updated_at BEFORE UPDATE ON public.user_refresh_tokens FOR EACH ROW EXECUTE FUNCTION public.update_updated_at_column();


--
-- TOC entry 3611 (class 2620 OID 31221)
-- Name: users update_users_updated_at; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER update_users_updated_at BEFORE UPDATE ON public.users FOR EACH ROW EXECUTE FUNCTION public.update_updated_at_column();


--
-- TOC entry 3609 (class 2620 OID 31222)
-- Name: user_login user_login_update_audit; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER user_login_update_audit BEFORE UPDATE ON public.user_login FOR EACH ROW EXECUTE FUNCTION public.audit_user_login_update();

