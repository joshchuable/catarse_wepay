class CatarseWepay::WepayController < ApplicationController
  skip_before_filter :force_http
  SCOPE = "projects.contributions.checkout"
  layout :false

  require 'wepay'

  def review
  end

  def refund
    response = gateway.call('/checkout/refund', PaymentEngines.configuration[:wepay_access_token], {
        account_id: PaymentEngines.configuration[:wepay_account_id],
        checkout_id: contribution.payment_token,
        refund_reason: t('wepay_refund_reason', scope: SCOPE),
    })

    if response['state'] == 'refunded'
      flash[:notice] = I18n.t('projects.contributions.refund.success')
    else
      flash[:alert] = refund_request.try(:message) || I18n.t('projects.contributions.refund.error')
    end

    redirect_to main_app.admin_contributions_path
  end

  def ipn
    if contribution && (contribution.payment_method == 'WePay' || contribution.payment_method.nil?)
      response = gateway.call('/preapproval', PaymentEngines.configuration[:wepay_access_token], {
          preapproval_id: contribution.payment_token,
      })
      PaymentEngines.create_payment_notification contribution_id: contribution.id, extra_data: response
      if response["state"]
        case response["state"].downcase
        when 'new'
          contribution.confirm!
        when 'stopped'
          contribution.refund!
        when 'cancelled'
          contribution.cancel!
        when 'expired', 'failed'
          contribution.pendent!
        when 'authorized', 'reserved'
          contribution.waiting! if contribution.pending?
        end
      end
      contribution.update_attributes({
        :payment_service_fee => response['fee'],
        :payer_email => response['payer_email']
      })
    else
      return render status: 500, nothing: true
    end
    return render status: 200, nothing: true
  rescue Exception => e
    return render status: 500, text: e.inspect
  end

# Create new preapproval call
 def new
    response = gateway.call('/preapproval/create', contribution.project.user.wepay_access_token, {
        #account_id: will have to be changed to the WePay account ID of the project creators
        :account_id         => contribution.project.user.wepay_account_id_string,
        :amount             => (contribution.price_in_cents/100).round(2).to_s,
        :period             => 'once',
        :app_fee            => 0.04,
        :short_description  => t('wepay_description', scope: SCOPE, :project_name => contribution.project.name, :value => contribution.display_value),
        :type               => 'regular',
        :redirect_uri       => success_wepay_url(id: contribution.id),
        :callback_uri       => ipn_wepay_index_url(callback_uri_params)
    })

    p response

 end

# Checkout will eventually have to be put in a rake task that will run daily, and will batch.
 def pay
    # WePay Ruby SDK - http://git.io/a_c2uQ
    require 'wepay'

    # set _use_stage to false for live environments
     #wepay = WePay.new(PaymentEngines.configuration[:wepay_client_id], PaymentEngines.configuration[:wepay_client_secret], _use_stage = true)

     # create the pre-approval
     response = gateway.call('/preapproval/create', contribution.project.user.wepay_access_token, {
         :account_id         => contribution.project.user.wepay_account_id_string,
         :period             => 'once',
         :app_fee            => 0.04,
         :amount             => (contribution.price_in_cents/100).round(2).to_s,
         :mode               => 'regular',
         :short_description  => t('wepay_description', scope: SCOPE, :project_name => contribution.project.name, :value => contribution.display_value),
         :callback_uri       => ipn_wepay_index_url(callback_uri_params),
         :redirect_uri       => success_wepay_url(id: contribution.id)
       })

    #response = gateway.call('/checkout/create', PaymentEngines.configuration[:wepay_access_token], {
    #    account_id: PaymentEngines.configuration[:wepay_account_id],
    #    amount: (contribution.price_in_cents/100).round(2).to_s,
    #    short_description: t('wepay_description', scope: SCOPE, :project_name => contribution.project.name, :value => contribution.display_value),
    #    type: 'DONATION',
    #    redirect_uri: success_wepay_url(id: contribution.id),
    #    callback_uri: ipn_wepay_index_url(callback_uri_params)
    #})

    # display the response
    p response
    flash[:success] = t(response)
    if response['preapproval_id']
      contribution.update_attributes payment_method: 'WePay', payment_token: response['preapproval_id']
      redirect_to response['preapproval_uri']
    else
      flash[:failure] = t('wepay_error', scope: SCOPE)
      return redirect_to main_app.edit_project_contribution_path(project_id: contribution.project.id, id: contribution.id)
    end

    # response = gateway.call('/checkout/create', PaymentEngines.configuration[:wepay_access_token], {
    #     account_id: PaymentEngines.configuration[:wepay_account_id],
    #     amount: (contribution.price_in_cents/100).round(2).to_s,
    #     short_description: t('wepay_description', scope: SCOPE, :project_name => contribution.project.name, :value => contribution.display_value),
    #     type: 'DONATION',
    #     redirect_uri: success_wepay_url(id: contribution.id),
    #     callback_uri: ipn_wepay_index_url(callback_uri_params)
    # })
    # if response['checkout_uri']
    #   contribution.update_attributes payment_method: 'WePay', payment_token: response['checkout_id']
    #   redirect_to response['checkout_uri']
    # else
    #   flash[:failure] = t('wepay_error', scope: SCOPE)
    #   return redirect_to main_app.edit_project_contribution_path(project_id: contribution.project.id, id: contribution.id)
    # end
  end

  def callback_uri_params
    #{host: '52966c09.ngrok.com', port: 80} if Rails.env.development? #original
    #{host: 'funddit.me', port: 80} if Rails.env.production? #we could could combine this with the line above for testing purposes
    #{} #it's possible that these are to be used as overwriting and that an empty object will use the defaults. I think it's likely that this is the case.
    {host: 'funddit.me', port: 80} #It seems like this is a pretty safe bet for now, but I'm not positive
  end

  def success
    response = gateway.call('/preapproval', contribution.project.user.wepay_access_token, {
        preapproval_id: contribution.payment_token,
    })
    if response['state'] == 'approved'
      flash[:success] = t('success', scope: SCOPE)
      redirect_to main_app.project_contribution_path(project_id: contribution.project.id, id: contribution.id)
    else
      flash[:failure] = t('wepay_error', scope: SCOPE)
      redirect_to main_app.new_project_contribution_path(contribution.project)
    end
  end

  def contribution
    @contribution ||= if params['id']
                  PaymentEngines.find_payment(id: params['id'])
                elsif params['preapproval_id']
                  PaymentEngines.find_payment(payment_token: params['preapproval_id'])
                end
  end

  def gateway
    raise "[WePay] An API Client ID and Client Secret are required to make requests to WePay" unless PaymentEngines.configuration[:wepay_client_id] and PaymentEngines.configuration[:wepay_client_secret]
    @gateway ||= WePay.new(PaymentEngines.configuration[:wepay_client_id], PaymentEngines.configuration[:wepay_client_secret], false)
  end

end
