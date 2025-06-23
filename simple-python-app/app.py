from flask import Flask

app = Flask(__name__)  

@app.route('/')
def hello():
    return '<h1>Hello, World! Your CI/CD Pipeline is working!</h1>'

@app.route('/health')
def health():
    return {'status': 'healthy', 'message': 'Application is running successfully'}

if __name__ == '__main__':
    app.run(host='0.0.0.0', port=5000, debug=True)
