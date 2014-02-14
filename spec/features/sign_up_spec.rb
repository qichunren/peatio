require 'spec_helper'

describe 'Sign up', js: true do
  before { Resque.inline = true } # doesn't work

  def fill_in_sign_up_form
    visit root_path
    click_on I18n.t('header.signup')
    fill_in 'email', with: 'wei@example.com'
    fill_in 'password', with: 'Password123'
    fill_in 'password_confirmation', with: 'Password123'
    click_on I18n.t('header.signup')
  end

  def email_activation_link
    sleep 1 # not sure why I have to sleep and make this js just to get mail =(

    mail = ActionMailer::Base.deliveries.last
    expect(mail).to be_present
    expect(mail.to).to eq(['wei@example.com'])
    expect(mail.subject).to eq(I18n.t 'token_mailer.activation.subject')

    mail.body.to_s.match(/http:\/\/peatio\.dev(.*)/)[1]
  end

  it 'allows a user to sign up and activate the account' do
    fill_in_sign_up_form
    visit email_activation_link
    expect(page).to have_content(I18n.t('header.market'))
  end

  it 'allows a user to sign up and activate the account in a different browser' do
    fill_in_sign_up_form
    Capybara.current_session.driver.browser.clear_cookies
    visit email_activation_link
    expect(page).to have_content(I18n.t('activations.edit.success'))

    login Identity.last
    expect(page).to have_content(I18n.t('header.market'))
  end

  it 'allows user to resend confirmation email' do
    fill_in_sign_up_form

    first_activation_link = email_activation_link

    Timecop.travel(6.minutes.from_now)

    click_on I18n.t('helpers.submit.activation.update')
    link = email_activation_link
    expect(link).to_not eq(first_activation_link)

    visit email_activation_link
    expect(page).to have_content(I18n.t('header.market'))
  end

  after { Resque.inline = false }
end